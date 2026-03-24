defmodule Froth.TestSupport.FakeCodexSession do
  use GenServer

  @registry Froth.Codex.SessionRegistry
  @pubsub Froth.PubSub

  def child_spec(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    snapshot = Keyword.get(opts, :snapshot, default_snapshot(session_id))

    GenServer.start_link(
      __MODULE__,
      %{session_id: session_id, snapshot: normalize_snapshot(session_id, snapshot)},
      name: via(session_id)
    )
  end

  def ensure_started(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_link(Keyword.put(opts, :session_id, session_id))
    end
  end

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  def snapshot(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :snapshot)
  end

  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    GenServer.call(via(session_id), {:send_prompt, prompt})
  end

  def set_snapshot(session_id, snapshot) when is_binary(session_id) and is_map(snapshot) do
    GenServer.call(via(session_id), {:set_snapshot, snapshot})
  end

  def crash(session_id, reason \\ :boom) when is_binary(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        Process.exit(pid, reason)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  def topic(session_id) when is_binary(session_id), do: "codex:session:#{session_id}"

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, state.snapshot}, state}
  end

  def handle_call({:send_prompt, _prompt}, _from, state) do
    turn_id = "turn-#{System.unique_integer([:positive])}"

    snapshot =
      state.snapshot
      |> Map.put(:active_turn_id, turn_id)
      |> append_entry(:status, "working (#{turn_id})")

    broadcast_update(state.session_id)
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  def handle_call({:set_snapshot, snapshot}, _from, state) do
    normalized =
      state.session_id
      |> normalize_snapshot(snapshot)
      |> carry_forward_entries(state.snapshot)
      |> annotate_transition(state.snapshot)

    broadcast_update(state.session_id)
    {:reply, :ok, %{state | snapshot: normalized}}
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  defp broadcast_update(session_id) do
    Froth.broadcast(topic(session_id), {:codex_session_updated, session_id})
  end

  defp default_snapshot(session_id) do
    %{
      session_id: session_id,
      status: :ready,
      thread_id: "thread-#{session_id}",
      active_turn_id: nil,
      entries: [],
      token_usage: nil,
      rate_limits: nil,
      auth: nil,
      runtime: %{}
    }
  end

  defp normalize_snapshot(session_id, snapshot) when is_map(snapshot) do
    default_snapshot(session_id)
    |> Map.merge(snapshot)
    |> Map.put(:session_id, session_id)
  end

  defp annotate_transition(next_snapshot, previous_snapshot)
       when is_map(next_snapshot) and is_map(previous_snapshot) do
    previous_turn_id = previous_snapshot[:active_turn_id]
    next_turn_id = next_snapshot[:active_turn_id]

    cond do
      is_nil(previous_turn_id) and is_binary(next_turn_id) ->
        append_entry(next_snapshot, :status, "working (#{next_turn_id})")

      is_binary(previous_turn_id) and is_nil(next_turn_id) and next_snapshot[:status] != :error ->
        append_entry(next_snapshot, :status, "turn completed")

      true ->
        next_snapshot
    end
  end

  defp carry_forward_entries(next_snapshot, previous_snapshot)
       when is_map(next_snapshot) and is_map(previous_snapshot) do
    previous_entries = Map.get(previous_snapshot, :entries, [])
    next_entries = Map.get(next_snapshot, :entries, [])

    merged_entries =
      (previous_entries ++ next_entries)
      |> Enum.uniq_by(fn entry ->
        entry[:id] || entry["id"] || entry[:sequence] || entry["sequence"]
      end)

    Map.put(next_snapshot, :entries, merged_entries)
  end

  defp append_entry(snapshot, kind, body)
       when is_map(snapshot) and is_atom(kind) and is_binary(body) do
    sequence =
      snapshot
      |> Map.get(:entries, [])
      |> Enum.map(&(&1[:sequence] || 0))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    entry = %{id: "e-#{sequence}", kind: kind, body: body, sequence: sequence}
    Map.update(snapshot, :entries, [entry], &(&1 ++ [entry]))
  end
end
