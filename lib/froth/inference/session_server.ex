defmodule Froth.Inference.SessionServer do
  @moduledoc """
  Runtime process for a single active inference session.
  """

  use GenServer

  alias Froth.Inference.Session
  alias Froth.Repo
  alias Froth.Inference.InferenceSession

  @registry Froth.Inference.SessionRegistry
  @supervisor Froth.Inference.SessionSupervisor

  def start_new_messages(config, messages, opts \\ [])
      when is_map(config) and is_list(messages) and messages != [] and is_list(opts) do
    owner_pid = Keyword.get(opts, :owner_pid)

    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, %{config: config, mode: {:new_messages, messages}, owner_pid: owner_pid}}
    )
  end

  def start_new_message(config, msg, opts \\ []) when is_map(config) and is_map(msg) do
    start_new_messages(config, [msg], opts)
  end

  def ensure_started(config, inference_session_id, opts \\ [])
      when is_map(config) and is_integer(inference_session_id) and is_list(opts) do
    owner_pid = Keyword.get(opts, :owner_pid)

    case whereis(config.id, inference_session_id) do
      nil ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__,
                %{config: config, mode: {:adopt, inference_session_id}, owner_pid: owner_pid}}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          other ->
            other
        end

      pid ->
        {:ok, pid}
    end
  end

  def whereis(bot_id, inference_session_id)
      when is_binary(bot_id) and is_integer(inference_session_id) do
    case Registry.lookup(@registry, {bot_id, inference_session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 500,
      type: :worker
    }
  end

  def start_link(%{config: config, mode: mode} = args) when is_map(config) do
    owner_pid = Map.get(args, :owner_pid)
    GenServer.start_link(__MODULE__, %{config: config, mode: mode, owner_pid: owner_pid})
  end

  @impl true
  def init(%{config: config, mode: mode, owner_pid: owner_pid}) do
    runtime_state = %{config: config, tasks: %{}, typing_timers: %{}}

    state = %{
      config: config,
      runtime_state: runtime_state,
      inference_session_id: nil,
      owner_pid: owner_pid
    }

    send(self(), {:boot, mode})
    {:ok, state}
  end

  @impl true
  def handle_info({:boot, {:new_messages, messages}}, state) do
    runtime_state = Session.start_inference_session_messages(messages, state.runtime_state)
    inference_session_id = infer_session_id(runtime_state)

    state =
      state
      |> Map.put(:runtime_state, runtime_state)
      |> Map.put(:inference_session_id, inference_session_id)
      |> register_if_needed()
      |> notify_started()

    maybe_stop_if_idle(state)
  end

  def handle_info({:boot, {:adopt, inference_session_id}}, state) do
    state =
      state
      |> Map.put(:inference_session_id, inference_session_id)
      |> register_if_needed()
      |> notify_started()

    {:noreply, state}
  end

  def handle_info({ref, {:stream_result, inference_session_id, result}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {_, tasks} = Map.pop(state.runtime_state.tasks, ref)

    runtime_state =
      %{state.runtime_state | tasks: tasks} |> Session.cancel_typing(inference_session_id)

    {:noreply, runtime_state} =
      Session.handle_stream_result(inference_session_id, result, runtime_state)

    maybe_stop_if_idle(%{state | runtime_state: runtime_state})
  end

  def handle_info(
        {ref, {:tool_result, inference_session_id, tool_use_id, result, is_error}},
        state
      )
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {_, tasks} = Map.pop(state.runtime_state.tasks, ref)
    runtime_state = %{state.runtime_state | tasks: tasks}

    {:noreply, runtime_state} =
      Session.handle_tool_result(
        inference_session_id,
        tool_use_id,
        result,
        is_error,
        runtime_state
      )

    maybe_stop_if_idle(%{state | runtime_state: runtime_state})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.runtime_state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{:streaming, inference_session_id, _pid}, tasks} ->
        runtime_state =
          %{state.runtime_state | tasks: tasks}
          |> Session.cancel_typing(inference_session_id)

        {:noreply, runtime_state} =
          Session.handle_stream_crash(inference_session_id, reason, runtime_state)

        maybe_stop_if_idle(%{state | runtime_state: runtime_state})

      {{:streaming, inference_session_id}, tasks} ->
        runtime_state =
          %{state.runtime_state | tasks: tasks}
          |> Session.cancel_typing(inference_session_id)

        {:noreply, runtime_state} =
          Session.handle_stream_crash(inference_session_id, reason, runtime_state)

        maybe_stop_if_idle(%{state | runtime_state: runtime_state})

      {{:tool_exec, inference_session_id, tool_use_id, _pid}, tasks} ->
        runtime_state = %{state.runtime_state | tasks: tasks}

        {:noreply, runtime_state} =
          Session.handle_tool_crash(inference_session_id, tool_use_id, reason, runtime_state)

        maybe_stop_if_idle(%{state | runtime_state: runtime_state})
    end
  end

  def handle_info({:typing, chat_id}, state) do
    state.config.effect_executor.send_typing(state.runtime_state, chat_id)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:resume, inference_session_id}, state) do
    {:noreply, runtime_state} =
      Session.check_all_tools_resolved(inference_session_id, state.runtime_state)

    state =
      state
      |> Map.put(:inference_session_id, inference_session_id)
      |> Map.put(:runtime_state, runtime_state)
      |> register_if_needed()

    maybe_stop_if_idle(state)
  end

  def handle_cast({:continue_loop, inference_session_id}, state) do
    {:noreply, runtime_state} = Session.continue_loop(inference_session_id, state.runtime_state)
    state = %{state | runtime_state: runtime_state}
    maybe_stop_if_idle(state)
  end

  def handle_cast({:stop_loop, inference_session_id}, state) do
    {:noreply, runtime_state} = Session.stop_loop(inference_session_id, state.runtime_state)
    state = %{state | runtime_state: runtime_state}
    maybe_stop_if_idle(state)
  end

  def handle_cast({:resolve_tool, ref, action}, state) do
    {:noreply, runtime_state} = Session.resolve_tool(ref, action, state.runtime_state)
    state = %{state | runtime_state: runtime_state}
    maybe_stop_if_idle(state)
  end

  def handle_cast({:abort_tool, ref}, state) do
    {:noreply, runtime_state} = Session.abort_tool(ref, state.runtime_state)
    state = %{state | runtime_state: runtime_state}
    maybe_stop_if_idle(state)
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if reason != :normal and reason != :shutdown do
      require Logger

      Logger.error(
        event: :session_server_crash,
        inference_session_id: state[:inference_session_id],
        bot_id: get_in(state, [:config, :id]),
        reason: inspect(reason, limit: 500)
      )
    end

    notify_stopped(state)
    :ok
  end

  defp register_if_needed(%{inference_session_id: inference_session_id} = state)
       when is_integer(inference_session_id) do
    _ = Registry.register(@registry, {state.config.id, inference_session_id}, true)
    state
  end

  defp register_if_needed(state), do: state

  defp infer_session_id(runtime_state) do
    task_id =
      Enum.find_value(runtime_state.tasks, fn
        {_ref, {:streaming, id, _pid}} when is_integer(id) -> id
        {_ref, {:streaming, id}} when is_integer(id) -> id
        _ -> nil
      end)

    case task_id do
      id when is_integer(id) ->
        id

      _ ->
        runtime_state.typing_timers
        |> Map.keys()
        |> Enum.find(&is_integer/1)
    end
  end

  defp maybe_stop_if_idle(%{inference_session_id: inference_session_id} = state)
       when is_integer(inference_session_id) do
    idle? =
      map_size(state.runtime_state.tasks) == 0 and
        map_size(state.runtime_state.typing_timers) == 0

    if idle? and terminal_or_waiting_status?(inference_session_id) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp maybe_stop_if_idle(state), do: {:noreply, state}

  defp terminal_or_waiting_status?(inference_session_id) do
    case Repo.get(InferenceSession, inference_session_id) do
      %{status: status} when status in ["awaiting_tools", "done", "error", "stopped"] -> true
      _ -> false
    end
  end

  defp notify_started(%{owner_pid: owner_pid, inference_session_id: inference_session_id} = state)
       when is_pid(owner_pid) and is_integer(inference_session_id) do
    send(owner_pid, {:session_server_started, self(), inference_session_id})
    state
  end

  defp notify_started(state), do: state

  defp notify_stopped(%{owner_pid: owner_pid, inference_session_id: inference_session_id})
       when is_pid(owner_pid) and is_integer(inference_session_id) do
    send(owner_pid, {:session_server_stopped, self(), inference_session_id})
  end

  defp notify_stopped(_), do: :ok
end
