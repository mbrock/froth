defmodule Froth.Tools.Definition do
  @moduledoc false

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse

  @callback name() :: String.t()
  @callback label() :: String.t()
  @callback spec() :: map()
  @callback execute(Context.t(), ToolUse.t(), keyword()) ::
              {:ok, term()} | {:error, String.t()} | {:await, term()}
end
