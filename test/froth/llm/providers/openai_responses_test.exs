defmodule Froth.LLM.Providers.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.OpenAIResponses
  alias Froth.LLM.Request

  test "build_request encodes responses-api input, instructions, tools, reasoning, and verbosity" do
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
      provider_options: %{"reasoning_effort" => "medium", "text_verbosity" => "low"}
    }

    {:ok, %{body: body}} = OpenAIResponses.build_request(request)

    assert body["model"] == "gpt-5.4"
    assert body["instructions"] == "system prompt"
    assert body["max_output_tokens"] == 1024
    assert body["reasoning"] == %{"effort" => "medium"}
    assert body["text"] == %{"verbosity" => "low"}

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

  test "build_request encodes user image blocks into responses input items" do
    request = %Request{
      provider: OpenAIResponses,
      endpoint: "https://example.test/v1/responses",
      headers: [{"authorization", "Bearer test"}],
      model: "gpt-5.4",
      messages: [
        Message.user([
          %{"type" => "text", "text" => "What is in these images?"},
          %{
            "type" => "image",
            "source" => %{
              "type" => "base64",
              "media_type" => "image/png",
              "data" => "aGVsbG8="
            }
          },
          %{
            "type" => "image",
            "source" => %{
              "type" => "url",
              "url" => "https://example.test/cat.png"
            }
          }
        ])
      ]
    }

    {:ok, %{body: body}} = OpenAIResponses.build_request(request)

    assert body["input"] == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "What is in these images?"},
                 %{
                   "type" => "input_image",
                   "image_url" => "data:image/png;base64,aGVsbG8="
                 },
                 %{"type" => "input_image", "image_url" => "https://example.test/cat.png"}
               ]
             }
           ]
  end
end
