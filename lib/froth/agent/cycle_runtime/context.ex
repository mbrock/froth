defmodule Froth.Agent.CycleRuntime.Context do
  @moduledoc """
  The structured context the runtime hands to `Telegram.ToolExecution`
  and `Agent.FailureIntervention` for each prepare/commit/execute
  tool call.

  Instead of flattening a runtime state snapshot into a grab-bag of 20
  keys, Context just references the actual structs the runtime already
  holds and lets downstream readers pattern-match on them.

  Slots:

    * `:cycle_id` — the cycle's DB id (also the registry key).
    * `:cycle` — the `%Froth.Agent.Cycle{}` row (carries `:provider`).
    * `:bot_config` — a `%Froth.Telegram.Bot.Config{}` snapshot, or
      `nil` in fully headless mode (run_adhoc without chat_id).
    * `:surface` — a `%Froth.Agent.Surface{}` (session/chat/reply_to).
    * `:view` — a `%Froth.Agent.CycleRuntime.View{}` (narration,
      last_sent, active_task_ids).
    * `:tool_call` — the `%Froth.Agent.ToolUse{}` being prepared /
      committed / executed.
    * `:spam` — boolean; when false, Telegram-facing tools no-op.
    * `:system_prompt` — resolved at construction time from
      `bot_config.system_prompt_fun` with the current chat_id.
    * `:tool_specs` — resolved at construction time from
      `bot_config.tools` or `tools_module.specs_for_api/0`.
  """

  alias Froth.Agent.{Cycle, Surface, ToolUse}
  alias Froth.Agent.CycleRuntime.View
  alias Froth.Telegram.Bot.Config, as: BotConfig

  @enforce_keys [:cycle_id, :tool_call]
  defstruct [
    :cycle_id,
    :cycle,
    :bot_config,
    :surface,
    :view,
    :tool_call,
    :system_prompt,
    :tool_specs,
    spam: true
  ]

  @type t :: %__MODULE__{
          cycle_id: String.t(),
          cycle: Cycle.t() | nil,
          bot_config: BotConfig.t() | nil,
          surface: Surface.t() | nil,
          view: View.t() | nil,
          tool_call: ToolUse.t(),
          system_prompt: String.t() | nil,
          tool_specs: [map()],
          spam: boolean()
        }
end
