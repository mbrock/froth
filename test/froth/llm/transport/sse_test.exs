defmodule Froth.LLM.Transport.SSETest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Transport.SSE

  test "flushes a final unterminated event at end of stream" do
    assert {:ok,
            %{
              acc: [%{"type" => "response.completed"}],
              diagnostics: diagnostics
            }} =
             SSE.consume_chunks(
               [
                 "event: response.completed\n",
                 ~s[data: {"type":"response.completed"}]
               ],
               [],
               fn payload, _raw, acc -> {:cont, [payload | acc]} end
             )

    assert diagnostics.raw_event_count == 1
    assert diagnostics.saw_done == false
    assert diagnostics.trailing_buffer == nil
  end

  test "records JSON decode failures instead of silently discarding them" do
    assert {:ok, %{acc: [], diagnostics: diagnostics}} =
             SSE.consume_chunks(
               [
                 "event: broken\n",
                 ~s[data: {"type":"response.completed"\n\n]
               ],
               [],
               fn payload, _raw, acc -> {:cont, [payload | acc]} end
             )

    assert diagnostics.raw_event_count == 1
    assert diagnostics.json_decode_error_count == 1

    assert [%{"data" => data, "error" => error}] =
             diagnostics.json_decode_errors

    assert data =~ "\"response.completed\""
    assert error != ""
  end
end
