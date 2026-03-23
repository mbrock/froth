defmodule Froth.Agent.Config do
  @type t :: %__MODULE__{
          provider: atom() | String.t() | module() | nil,
          system: String.t() | nil,
          model: String.t() | nil,
          tools: [map()],
          tool_executor: GenServer.server(),
          tool_timeout_ms: pos_integer() | nil,
          context: map() | nil,
          thinking: map() | nil,
          effort: String.t() | nil
        }

  defstruct [
    :provider,
    :system,
    :model,
    :tool_executor,
    :tool_timeout_ms,
    :context,
    :thinking,
    :effort,
    tools: []
  ]
end
