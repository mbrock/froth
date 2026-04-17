defmodule Froth.Telegram.Bot.CycleState do
  @moduledoc """
  The Bot's handle on the currently-running cycle.

  The Bot holds `cycle_state: nil` when idle or `%#{__MODULE__}{}` when
  a cycle is live. All the cycle's live state (narration, last-sent,
  active tasks, buffered user messages, awaiting-user-input flag) lives
  on the `Froth.Agent.CycleRuntime` process — this struct just carries
  the handles the Bot needs for routing and dispatch.

  Fields:

    * `:cycle` — the `%Froth.Agent.Cycle{}` DB row (for pattern-matching
      on cycle id and reading the cycle's provider in display paths).
    * `:cycle_runtime_pid` / `:cycle_runtime_ref` — the
      `Froth.Agent.CycleRuntime` GenServer and its monitor reference.
      Terminating the runtime cascades to the Worker via their link.
    * `:chat_id` / `:reply_to` — Telegram chat and the message the cycle
      is answering. The runtime has its own copy for tool execution;
      the Bot keeps one for its own side-effects (stop notifications,
      fallback agent-response sending).
  """

  alias Froth.Agent.Cycle

  @enforce_keys [:cycle, :cycle_runtime_pid, :cycle_runtime_ref, :chat_id]
  defstruct [
    :cycle,
    :cycle_runtime_pid,
    :cycle_runtime_ref,
    :chat_id,
    :reply_to
  ]

  @type t :: %__MODULE__{
          cycle: Cycle.t(),
          cycle_runtime_pid: pid(),
          cycle_runtime_ref: reference(),
          chat_id: integer(),
          reply_to: integer() | nil
        }
end
