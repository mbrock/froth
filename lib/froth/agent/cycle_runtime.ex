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

  Scaffolding stage: this module currently carries only minimal state
  (ids) so the supervision tree, registry, and lifecycle can be wired up
  and exercised in isolation. The per-cycle fields that live on
  `Froth.Telegram.Bot.CycleState` today (worker_pid, narration,
  last_sent, pending_ask, active_tasks, etc.) move in during step 2 of
  the rollout, at which point this module takes ownership of the Worker
  process.
  """

  use GenServer, restart: :temporary

  @registry Froth.Agent.CycleRegistry
  @supervisor Froth.Agent.CycleSupervisor

  @type opts :: [
          cycle_id: String.t(),
          bot_id: String.t() | nil,
          parent_cycle_id: String.t() | nil
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

  # --- GenServer callbacks ---

  @impl true
  def init(opts) when is_list(opts) do
    state = %{
      cycle_id: Keyword.fetch!(opts, :cycle_id),
      bot_id: Keyword.get(opts, :bot_id),
      parent_cycle_id: Keyword.get(opts, :parent_cycle_id)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
