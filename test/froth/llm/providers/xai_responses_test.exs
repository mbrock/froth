defmodule Froth.LLM.Providers.XAIResponsesTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Providers.XAIResponses
  alias Froth.LLM.Store

  test "correlates function call argument deltas by xai item id" do
    store = Store.new()

    {open_edits, _done?} =
      XAIResponses.decode_payload(
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "id" => "fc_123",
            "call_id" => "call_123",
            "name" => "send_message",
            "index" => 0
          }
        },
        store
      )

    store = Store.apply_edits(store, open_edits)

    {delta_edits, _done?} =
      XAIResponses.decode_payload(
        %{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "fc_123",
          "output_index" => 3,
          "delta" => "{\"text\":\"hi\"}"
        },
        store
      )

    result = store |> Store.apply_edits(delta_edits) |> XAIResponses.finalize()

    assert result.content == [
             %{
               "type" => "tool_use",
               "id" => "call_123",
               "name" => "send_message",
               "input" => %{"text" => "hi"}
             }
           ]
  end

  test "drops incomplete tool call fragments during finalize" do
    store =
      Store.new()
      |> Store.apply_edits([
        %Froth.LLM.Edit{
          op: :append,
          resource: ["message", "tool_calls", "fc_orphan"],
          path: ["arguments_json"],
          value: "{\"text\":\"hi\"}",
          attrs: %{"id" => "fc_orphan"}
        }
      ])

    result = XAIResponses.finalize(store)

    assert result.content == []
  end
end
