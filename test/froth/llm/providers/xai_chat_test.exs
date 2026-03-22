defmodule Froth.LLM.Providers.XAIChatTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.XAIChat
  alias Froth.LLM.Request

  test "build_request encodes normalized messages for xai chat completions" do
    request = %Request{
      provider: XAIChat,
      endpoint: "https://example.test/v1/chat/completions",
      headers: [{"authorization", "Bearer test"}],
      model: "grok-4-1-fast-non-reasoning",
      max_tokens: 1024,
      messages: [
        Message.system("system prompt"),
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

    {:ok, %{body: body}} = XAIChat.build_request(request)

    assert body["model"] == "grok-4-1-fast-non-reasoning"
    assert body["max_tokens"] == 1024
    assert body["reasoning_effort"] == "low"
    assert [%{"type" => "function"}] = Enum.map(body["tools"], &Map.take(&1, ["type"]))

    assert body["messages"] == [
             %{"role" => "system", "content" => "system prompt"},
             %{"role" => "user", "content" => "hello"},
             %{
               "role" => "assistant",
               "content" => "working",
               "tool_calls" => [
                 %{
                   "id" => "call_1",
                   "type" => "function",
                   "function" => %{
                     "name" => "froth_echo",
                     "arguments" => ~s({"text":"hi"})
                   }
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "echoed: hi"}
           ]
  end
end
