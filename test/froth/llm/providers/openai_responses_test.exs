defmodule Froth.LLM.Providers.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.OpenAIResponses
  alias Froth.LLM.Request

  test "build_request encodes responses-api input, instructions, and built-in tools" do
    request = %Request{
      provider: OpenAIResponses,
      endpoint: "https://example.test/v1/responses",
      headers: [{"authorization", "Bearer test"}],
      model: "gpt-5.4",
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
        %{"type" => "web_search_preview"},
        %{
          "name" => "froth_echo",
          "description" => "Echo text back.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}}
          }
        }
      ],
      provider_options: %{"reasoning_effort" => "medium"}
    }

    {:ok, %{body: body}} = OpenAIResponses.build_request(request)

    assert body["model"] == "gpt-5.4"
    assert body["instructions"] == "system prompt"
    assert body["max_output_tokens"] == 1024
    assert body["reasoning"] == %{"effort" => "medium"}

    assert body["input"] == [
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
             %{"type" => "web_search_preview"},
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
end
