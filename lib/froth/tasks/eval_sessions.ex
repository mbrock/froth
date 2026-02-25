defmodule Froth.Tasks.EvalSessions do
  @moduledoc """
  In-memory session store for Elixir eval bindings.

  A session represents a stateful eval environment where variable bindings
  persist between `elixir_eval` calls.
  """

  use GenServer

  @session_ttl_ms :timer.hours(6)
  @prune_interval_ms :timer.minutes(10)

  @type session_id :: String.t()
  @type binding_list :: keyword()

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec ensure_session(session_id() | nil) :: {session_id(), boolean()}
  def ensure_session(session_id \\ nil) do
    GenServer.call(__MODULE__, {:ensure_session, session_id})
  end

  @spec binding(session_id()) :: binding_list()
  def binding(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:binding, session_id})
  end

  @spec put_binding(session_id(), binding_list()) :: :ok
  def put_binding(session_id, binding) when is_binary(session_id) and is_list(binding) do
    GenServer.call(__MODULE__, {:put_binding, session_id, binding})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_state) do
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:ensure_session, provided_id}, _from, state) do
    session_id =
      case provided_id do
        id when is_binary(id) and id != "" -> id
        _ -> generate_session_id()
      end

    now = now_ms()

    {created?, sessions} =
      case Map.get(state.sessions, session_id) do
        nil ->
          {true, Map.put(state.sessions, session_id, %{binding: [], updated_at: now})}

        session ->
          {false, Map.put(state.sessions, session_id, %{session | updated_at: now})}
      end

    {:reply, {session_id, created?}, %{state | sessions: sessions}}
  end

  def handle_call({:binding, session_id}, _from, state) do
    now = now_ms()

    {binding, sessions} =
      case Map.get(state.sessions, session_id) do
        nil ->
          {[], Map.put(state.sessions, session_id, %{binding: [], updated_at: now})}

        session ->
          {session.binding, Map.put(state.sessions, session_id, %{session | updated_at: now})}
      end

    {:reply, binding, %{state | sessions: sessions}}
  end

  def handle_call({:put_binding, session_id, binding}, _from, state) do
    now = now_ms()

    sessions =
      Map.put(state.sessions, session_id, %{
        binding: binding,
        updated_at: now
      })

    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now_ms() - @session_ttl_ms

    sessions =
      state.sessions
      |> Enum.reject(fn {_session_id, session} -> session.updated_at < cutoff end)
      |> Map.new()

    Process.send_after(self(), :prune, @prune_interval_ms)
    {:noreply, %{state | sessions: sessions}}
  end

  # --- Private ---

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp generate_session_id do
    hex = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "eval_session_#{hex}"
  end
end
