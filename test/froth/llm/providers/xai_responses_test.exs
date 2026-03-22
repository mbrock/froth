defmodule Froth.LLM.Providers.XAIResponsesTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.XAIResponses
  alias Froth.LLM.Request
  alias Froth.LLM.Store

  test "build_request encodes normalized messages and built-in tools" do
    request = %Request{
      provider: XAIResponses,
      endpoint: "https://example.test/v1/responses",
      headers: [{"authorization", "Bearer test"}],
      model: "grok-4-1-fast-non-reasoning",
      system: "system prompt",
      max_tokens: 1024,
      messages: [
        Message.user("hello"),
        Message.assistant([
          %{"type" => "text", "text" => "working"},
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "froth_echo",
            "input" => %{"text" => "hi"}
          }
        ]),
        Message.user([
          %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "echoed: hi"}
        ])
      ],
      tools: [
        %{"type" => "web_search"},
        %{
          "name" => "froth_echo",
          "description" => "Echo text back.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}}
          }
        }
      ],
      provider_options: %{"reasoning_effort" => "low"}
    }

    {:ok, %{body: body}} = XAIResponses.build_request(request)

    assert body["model"] == "grok-4-1-fast-non-reasoning"
    assert body["max_output_tokens"] == 1024
    assert body["reasoning"] == %{"effort" => "low"}

    assert body["input"] == [
             %{"role" => "system", "content" => "system prompt"},
             %{"role" => "user", "content" => "hello"},
             %{"role" => "assistant", "content" => "working"},
             %{
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "froth_echo",
               "arguments" => ~s({"text":"hi"})
             },
             %{"type" => "function_call_output", "call_id" => "call_1", "output" => "echoed: hi"}
           ]

    assert body["tools"] == [
             %{"type" => "web_search"},
             %{
               "type" => "function",
               "name" => "froth_echo",
               "description" => "Echo text back.",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{"text" => %{"type" => "string"}}
               }
             }
           ]
  end

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
