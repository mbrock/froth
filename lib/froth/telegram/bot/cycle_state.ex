defmodule Froth.Telegram.Bot.CycleState do
  @moduledoc """
  Per-cycle state held by `Froth.Telegram.Bot` while an agent cycle is
  running. The Bot's own struct holds `cycle_state: nil` when idle or
  `%#{__MODULE__}{}` when a cycle is live.

  Fields:

    * `:cycle` — the `%Froth.Agent.Cycle{}` DB row.
    * `:cycle_runtime_pid` / `:cycle_runtime_ref` — the
      `Froth.Agent.CycleRuntime` GenServer and its monitor reference.
      The CycleRuntime owns the Worker; terminating the runtime cascades
      to the Worker via their link. See RFC-0021.
    * `:chat_id` / `:reply_to` — Telegram chat and the message the cycle
      is answering.
    * `:last_sent` — `nil` or `%{id, text}` of the most recent outbound
      reply, for editing in place (cost footer, failure intervention).
    * `:narration` — `nil` or `%{message_id, text, mode}` of the running
      italic/markdown narration message, for append-editing.
    * `:awaiting_user_input?` — true while a pending-ask has parked the
      Worker.
    * `:mid_cycle_messages` — buffered user messages received while this
      cycle was running. Drained into the next cycle or injected into
      the next tool result.
  """

  alias Froth.Agent.Cycle

  @enforce_keys [:cycle, :cycle_runtime_pid, :cycle_runtime_ref, :chat_id]
  defstruct [
    :cycle,
    :cycle_runtime_pid,
    :cycle_runtime_ref,
    :chat_id,
    :reply_to,
    :last_sent,
    :narration,
    awaiting_user_input?: false,
    mid_cycle_messages: []
  ]

  @type last_sent :: %{id: integer() | nil, text: binary()}
  @type narration :: %{
          message_id: integer(),
          text: binary(),
          mode: :italic | :markdown
        }

  @type t :: %__MODULE__{
          cycle: Cycle.t(),
          cycle_runtime_pid: pid(),
          cycle_runtime_ref: reference(),
          chat_id: integer(),
          reply_to: integer() | nil,
          last_sent: last_sent() | nil,
          narration: narration() | nil,
          awaiting_user_input?: boolean(),
          mid_cycle_messages: [map()]
        }
end
