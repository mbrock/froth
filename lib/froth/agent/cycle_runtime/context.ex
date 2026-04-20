defmodule Froth.Agent.CycleRuntime.Context do
  @moduledoc """
  The structured context the runtime hands to `Telegram.ToolExecution`
  and `Agent.FailureIntervention` for each prepare/commit/execute
  tool call.

  Instead of flattening a runtime state snapshot into a grab-bag of 20
  keys, Context just references the actual structs the runtime already
  holds and lets downstream readers pattern-match on them.

  Purely cycle-level state. A `%Context{}` describes what's true
  about the cycle at some moment — identity, surface, view — and does
  *not* carry any per-tool-call data. Tool execution functions take a
  `%Context{}` plus a separately-passed `%Froth.Agent.ToolUse{}`:

      ToolExecution.execute(ctx, tool_call)
      FailureIntervention.maybe_intervene(result, ctx, tool_call)

  The runtime holds exactly one of these on its state and overlays the
  `:surface` field per-call when the Worker's invocation kwlist
  supplies overrides.

  Slots:

    * `:cycle_id` — the cycle's DB id (also the registry key).
    * `:cycle` — the `%Froth.Agent.Cycle{}` row (carries `:provider`).
    * `:bot_config` — the owning bot's `%Froth.Telegram.Bot.Config{}`
      snapshot.
    * `:surface` — a `%Froth.Agent.Surface{}` (session/chat/reply_to).
    * `:view` — a `%Froth.Agent.CycleRuntime.View{}` (narration,
      last_sent, active_task_ids, awaiting_user_input?).
    * `:spam` — boolean; when false, Telegram-facing tools no-op.
    * `:system_prompt` — resolved at cycle start from
      `bot_config.system_prompt_fun` with the current chat_id.
    * `:tool_specs` — resolved at cycle start from `bot_config.tools`
      or `tools_module.specs_for_api/0`.
  """

  alias Froth.Agent.{Cycle, Surface}
  alias Froth.Agent.CycleRuntime.View
  alias Froth.Telegram.Bot.Config, as: BotConfig

  @enforce_keys [:cycle_id, :surface, :view]
  defstruct [
    :cycle_id,
    :cycle,
    :bot_config,
    :surface,
    :view,
    :system_prompt,
    :tool_specs,
    spam: true
  ]

  @type t :: %__MODULE__{
          cycle_id: String.t(),
          cycle: Cycle.t() | nil,
          bot_config: BotConfig.t() | nil,
          surface: Surface.t(),
          view: View.t(),
          system_prompt: String.t() | nil,
          tool_specs: [map()],
          spam: boolean()
        }
end
