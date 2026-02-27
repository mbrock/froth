defmodule Froth.Agent.Config do
  @type t :: %__MODULE__{
          system: String.t() | nil,
          model: String.t() | nil,
          tools: [map()],
          tool_executor: GenServer.server(),
          context: map() | nil,
          thinking: map() | nil,
          effort: String.t() | nil
        }

  defstruct [:system, :model, :tool_executor, :context, :thinking, :effort, tools: []]
end
