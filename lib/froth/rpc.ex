defmodule Froth.RPC do
  @moduledoc "Run code on this node with IO routed to a remote caller."

  @doc """
  Eval code string with group_leader set to `gl` so IO goes there.
  Called from bin/rpc.
  """
  def eval(gl, code) when is_pid(gl) and is_binary(code) do
    Process.group_leader(self(), gl)
    {result, _bindings} = Code.eval_string(code)
    result
  end
end
