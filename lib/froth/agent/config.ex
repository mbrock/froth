defmodule Froth.Agent.Config do
  @type t :: %__MODULE__{
          provider: atom() | String.t() | module() | nil,
          system: String.t() | nil,
          model: String.t() | nil,
          max_tokens: pos_integer() | nil,
          tools: [map()],
          tool_executor: GenServer.server(),
          tool_timeout_ms: pos_integer() | nil,
          context: map() | nil,
          parent_span_id: String.t() | nil,
          thinking: map() | nil,
          effort: String.t() | nil,
          reasoning_summary: String.t() | nil
        }

  defstruct [
    :provider,
    :system,
    :model,
    :max_tokens,
    :tool_executor,
    :tool_timeout_ms,
    :context,
    :parent_span_id,
    :thinking,
    :effort,
    :reasoning_summary,
    tools: []
  ]
end
