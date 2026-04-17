defmodule Froth.Agent.Surface do
  @moduledoc """
  Where a cycle's output goes.

  Per RFC-0021, a cycle has three entities: agent identity (`%Bot.Config{}`),
  the cycle runtime itself, and a *surface* — the Telegram endpoint the
  cycle writes to.

  `session_id` is the TDLib session the bot is logged into. `chat_id`
  is the Telegram chat the cycle is answering in. `reply_to` is the
  message id the cycle's replies hang off (threads, anchors for
  pending-ask routing).

  In headless contexts (e.g. a cycle started directly via
  `CycleRuntime.run_to_completion/1` from a cron job), `chat_id` may
  be `nil` — tools that need a real chat refuse to operate; tools that
  don't (run_shell, elixir_eval) run unaffected.
  """

  defstruct [:session_id, :chat_id, :reply_to]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          chat_id: integer() | nil,
          reply_to: integer() | nil
        }
end
