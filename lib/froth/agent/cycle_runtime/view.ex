defmodule Froth.Agent.CycleRuntime.View do
  @moduledoc """
  A snapshot of the live UI state a cycle has produced so far.

  Passed to tools via `%CycleRuntime.Context{}` so they can reason
  about what the user has seen (for narration appends, cost-footer
  edits, and similar).

  Fields:

    * `:narration` — `nil` or `%{message_id, text, mode}`. The
      running italic/markdown "scroll" message the cycle edits in
      place during tool execution.
    * `:last_sent` — `nil` or `%{id, text}`. The most recent
      non-narration outbound message (a plain `send_message`, etc.).
    * `:active_task_ids` — sorted list of background task ids
      (`"shell:..."`, `"eval:..."`) this cycle has spawned.
  """

  defstruct narration: nil, last_sent: nil, active_task_ids: []

  @type narration :: %{
          message_id: integer(),
          text: binary(),
          mode: :italic | :markdown
        }

  @type last_sent :: %{id: integer() | nil, text: binary()}

  @type t :: %__MODULE__{
          narration: narration() | nil,
          last_sent: last_sent() | nil,
          active_task_ids: [String.t()]
        }
end
