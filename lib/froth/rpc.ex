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

  @doc """
  Stream an LLM completion, sending events as messages to `caller_pid`.
  """
  def stream_to(caller_pid, messages) do
    on_event = fn event -> send(caller_pid, {:event, event}) end
    result = Froth.Anthropic.stream_reply_with_tools(messages, on_event)
    send(caller_pid, {:done, result})
    result
  end
end
