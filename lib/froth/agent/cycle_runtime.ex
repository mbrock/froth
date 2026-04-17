defmodule Froth.Agent.CycleRuntime do
  @moduledoc """
  Supervised process driving one agent cycle.

  Every cycle — root or subagent — is a `Froth.Agent.CycleRuntime`.
  Root cycles are started under `Froth.Agent.CycleSupervisor`; subagent
  cycles are started under their parent runtime's own child
  DynamicSupervisor. Runtimes are registered in `Froth.Agent.CycleRegistry`
  keyed by `cycle_id` (globally unique), so any caller can address a live
  cycle via `Registry.lookup/2` or the `via/1` helper without going
  through the Bot.

  See `rfc/froth-rfc0021.xml` for the full design.

  ## Current scope (RFC-0021 step 2)

  CycleRuntime owns the Worker. When started with `:cycle` + `:worker_config`
  opts, `init/1` spawns a `Froth.Agent.Worker` via `start_link/1`, traps
  exits, and stops itself when the Worker terminates (mirroring the
  Worker's exit reason). Killing the runtime cascades to the Worker via
  the link, so `Process.exit(cycle_runtime_pid, reason)` is a single
  stop-the-cycle operation.

  The Bot is still the Worker's `tool_executor`; prepare/commit/execute
  tool calls continue to land on the Bot GenServer. That moves in a
  later step.

  ## Scaffolding mode

  Supplying only the identity opts (`:cycle_id`, `:bot_id`, `:parent_cycle_id`)
  starts a runtime with no Worker. Used for registry / supervisor
  wiring tests. Do not rely on this in production code.
  """

  use GenServer, restart: :temporary

  alias Froth.Agent.{Config, Cycle, Worker}

  @registry Froth.Agent.CycleRegistry
  @supervisor Froth.Agent.CycleSupervisor

  @type opts :: [
          cycle_id: String.t(),
          bot_id: String.t() | nil,
          parent_cycle_id: String.t() | nil,
          cycle: Cycle.t() | nil,
          worker_config: Config.t() | nil
        ]

  # --- Public API ---

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    cycle_id = Keyword.fetch!(opts, :cycle_id)
    GenServer.start_link(__MODULE__, opts, name: via(cycle_id))
  end

  @doc """
  The `:via` tuple used to address a cycle runtime by its cycle id.
  Use with `GenServer.call/cast` or as a `name:` option.
  """
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(cycle_id) when is_binary(cycle_id) do
    {:via, Registry, {@registry, cycle_id}}
  end

  @doc "Returns the runtime pid for `cycle_id`, or `nil` if no live cycle has that id."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(cycle_id) when is_binary(cycle_id) do
    case Registry.lookup(@registry, cycle_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Returns `true` if a cycle runtime is live for `cycle_id`."
  @spec alive?(String.t()) :: boolean()
  def alive?(cycle_id) when is_binary(cycle_id) do
    whereis(cycle_id) != nil
  end

  @doc """
  Start a root-level cycle runtime under `Froth.Agent.CycleSupervisor`.
  Returns `{:ok, pid}` on success.
  """
  @spec start_root(opts()) :: DynamicSupervisor.on_start_child()
  def start_root(opts) when is_list(opts) do
    DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts})
  end

  @doc """
  Forward a pending-ask resolution to the Worker owned by this runtime.
  See `Froth.Agent.Worker.resolve_pending_ask/3`.
  """
  @spec resolve_pending_ask(pid(), String.t(), term()) :: term()
  def resolve_pending_ask(runtime_pid, pending_ask_id, resolution)
      when is_pid(runtime_pid) and is_binary(pending_ask_id) do
    GenServer.call(
      runtime_pid,
      {:resolve_pending_ask, pending_ask_id, resolution},
      :infinity
    )
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) when is_list(opts) do
    cycle = Keyword.get(opts, :cycle)
    worker_config = Keyword.get(opts, :worker_config)

    state = %{
      cycle_id: Keyword.fetch!(opts, :cycle_id),
      bot_id: Keyword.get(opts, :bot_id),
      parent_cycle_id: Keyword.get(opts, :parent_cycle_id),
      cycle: cycle,
      worker_pid: nil
    }

    case maybe_start_worker(cycle, worker_config) do
      {:ok, worker_pid} ->
        {:ok, %{state | worker_pid: worker_pid}}

      :skip ->
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:resolve_pending_ask, pending_ask_id, resolution}, _from, state) do
    case state.worker_pid do
      pid when is_pid(pid) ->
        reply = Worker.resolve_pending_ask(pid, pending_ask_id, resolution)
        {:reply, reply, state}

      nil ->
        {:reply, {:error, :no_worker}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, worker_pid, reason}, %{worker_pid: worker_pid} = state) do
    # Worker terminated. Mirror its reason — a normal Worker finish ends
    # the cycle runtime normally; a crash propagates the crash reason up
    # so the Bot's monitor sees it unchanged.
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp maybe_start_worker(%Cycle{} = cycle, %Config{} = config) do
    Process.flag(:trap_exit, true)

    case Worker.start_link({cycle, config}) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  defp maybe_start_worker(nil, nil), do: :skip
  defp maybe_start_worker(_cycle, _config), do: {:error, :invalid_worker_args}
end
