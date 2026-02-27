defmodule Froth.Inference.SessionScheduler do
  @moduledoc """
  Per-bot scheduler for inference session worker lifecycle and mention queueing.
  """

  use GenServer
  require Logger

  alias Froth.Inference.InferenceSession
  alias Froth.Inference.SessionServer
  alias Froth.Repo

  def start_link(opts \\ [])

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    config = Keyword.fetch!(opts, :config)
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, %{config: config}, name: name)
    else
      GenServer.start_link(__MODULE__, %{config: config})
    end
  end

  def enqueue_mention(server, msg) when is_pid(server) and is_map(msg) do
    GenServer.cast(server, {:enqueue_mention, msg})
  end

  def dispatch(server, inference_session_id, message)
      when is_pid(server) and is_integer(inference_session_id) do
    GenServer.cast(server, {:dispatch, inference_session_id, message})
  end

  @impl true
  def init(%{config: config}) do
    {:ok,
     %{
       config: config,
       active_session_id: nil,
       active_pid: nil,
       active_ref: nil,
       pending_mentions: [],
       debounce_ref: nil
     }}
  end

  @impl true
  def handle_cast({:enqueue_mention, msg}, state) do
    # Always add to pending, then (re)start a debounce timer.
    # This ensures a burst of messages (e.g. Telegram splitting a long
    # message across multiple parts) gets batched into one inference pass.
    state = %{state | pending_mentions: state.pending_mentions ++ [msg]}

    # Cancel any existing debounce timer
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)

    # Group chats get a longer debounce (5s) than DMs (1s)
    chat_id = msg["chat_id"] || 0
    delay = if chat_id < 0, do: 5_000, else: 1_000

    ref = Process.send_after(self(), :debounce_fire, delay)
    {:noreply, %{state | debounce_ref: ref}}
  end

  def handle_cast({:dispatch, inference_session_id, message}, state)
      when is_integer(inference_session_id) do
    {:noreply, dispatch_to_inference_session(state, inference_session_id, message)}
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:session_server_started, pid, inference_session_id}, state)
      when is_pid(pid) and is_integer(inference_session_id) do
    state =
      state
      |> monitor_session_pid(pid)
      |> Map.put(:active_session_id, inference_session_id)

    {:noreply, state}
  end

  def handle_info({:session_server_stopped, _pid, _inference_session_id}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state)
      when is_reference(ref) and is_pid(pid) do
    if ref == state.active_ref do
      state = %{state | active_pid: nil, active_ref: nil}

      state =
        case state.active_session_id && inference_session_status(state.active_session_id) do
          status when status in ["done", "error", "stopped"] ->
            state
            |> drain_queued_messages_from_session(state.active_session_id)
            |> Map.put(:active_session_id, nil)

          "awaiting_tools" ->
            state

          _ ->
            state
            |> drain_queued_messages_from_session(state.active_session_id)
            |> Map.put(:active_session_id, nil)
        end

      {:noreply, maybe_start_next_queued(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:debounce_fire, state) do
    state = %{state | debounce_ref: nil}

    if state.pending_mentions != [] and not active?(state) do
      {batch, rest} = pop_next_chat_batch(state.pending_mentions)
      {:noreply, start_new_mentions(batch, %{state | pending_mentions: rest})}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp dispatch_to_inference_session(state, inference_session_id, message)
       when is_integer(inference_session_id) do
    if active_session_conflict?(state, inference_session_id) do
      Logger.warning(
        event: :session_dispatch_conflict,
        active_session_id: state.active_session_id,
        requested_session_id: inference_session_id
      )

      state
    else
      case SessionServer.ensure_started(state.config, inference_session_id, owner_pid: self()) do
        {:ok, pid} ->
          GenServer.cast(pid, message)
          state |> monitor_session_pid(pid) |> Map.put(:active_session_id, inference_session_id)

        {:error, reason} ->
          Logger.error(
            event: :session_server_start_failed,
            inference_session_id: inference_session_id,
            reason: inspect(reason)
          )

          state
      end
    end
  end

  defp maybe_start_next_queued(state) do
    if active?(state) or state.pending_mentions == [] do
      state
    else
      {batch, rest} = pop_next_chat_batch(state.pending_mentions)
      start_new_mentions(batch, %{state | pending_mentions: rest})
    end
  end

  defp start_new_mentions(messages, state) when is_list(messages) and messages != [] do
    case SessionServer.start_new_messages(state.config, messages, owner_pid: self()) do
      {:ok, pid} ->
        monitor_session_pid(state, pid)

      {:error, reason} ->
        Logger.error(event: :session_server_start_failed, reason: inspect(reason))
        state
    end
  end

  defp pop_next_chat_batch([first | rest]) do
    chat_id = first["chat_id"]

    {batch_rev, rest_rev} =
      Enum.reduce(rest, {[first], []}, fn msg, {batch_acc, rest_acc} ->
        if msg["chat_id"] == chat_id do
          {[msg | batch_acc], rest_acc}
        else
          {batch_acc, [msg | rest_acc]}
        end
      end)

    {Enum.reverse(batch_rev), Enum.reverse(rest_rev)}
  end

  defp pop_next_chat_batch([]), do: {[], []}

  defp monitor_session_pid(state, pid) when is_pid(pid) do
    cond do
      state.active_pid == pid and is_reference(state.active_ref) ->
        state

      true ->
        if is_reference(state.active_ref) do
          Process.demonitor(state.active_ref, [:flush])
        end

        ref = Process.monitor(pid)
        %{state | active_pid: pid, active_ref: ref}
    end
  end

  defp active?(state) do
    is_pid(state.active_pid) or is_integer(state.active_session_id)
  end

  defp active_session_conflict?(state, requested_session_id) do
    current = state.active_session_id
    is_integer(current) and current != requested_session_id
  end

  defp inference_session_status(inference_session_id) when is_integer(inference_session_id) do
    case Repo.get(InferenceSession, inference_session_id) do
      nil -> nil
      %InferenceSession{status: status} -> status
    end
  end

  defp inference_session_status(_), do: nil

  defp drain_queued_messages_from_session(state, inference_session_id)
       when is_map(state) and is_integer(inference_session_id) do
    case Repo.get(InferenceSession, inference_session_id) do
      %InferenceSession{id: ^inference_session_id, queued_messages: msgs} = inference_session
      when is_list(msgs) and msgs != [] ->
        inference_session
        |> InferenceSession.changeset(%{queued_messages: []})
        |> Repo.update!()

        %{state | pending_mentions: state.pending_mentions ++ msgs}

      _ ->
        state
    end
  end

  defp drain_queued_messages_from_session(state, _), do: state
end
