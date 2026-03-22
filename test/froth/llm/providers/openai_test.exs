defmodule Froth.LLM.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.OpenAI
  alias Froth.LLM.Request

  test "build_request encodes normalized messages, tools, and provider metadata" do
    request = %Request{
      provider: OpenAI,
      endpoint: "https://example.test/v1/chat/completions",
      headers: [{"authorization", "Bearer test"}],
      model: "gpt-5-mini",
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
            "input" => %{"text" => "hi"},
            "extra_content" => %{"google" => %{"thought_signature" => "sig_123"}}
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
      provider_options: %{
        "include_usage" => true,
        "reasoning_effort" => "medium"
      }
    }

    {:ok, %{body: body}} = OpenAI.build_request(request)

    assert body["model"] == "gpt-5-mini"
    assert body["max_tokens"] == 1024
    assert body["stream_options"] == %{"include_usage" => true}
    assert body["reasoning_effort"] == "medium"
    assert [%{"type" => "function"}] = Enum.map(body["tools"], &Map.take(&1, ["type"]))

    assert [
             %{"role" => "system", "content" => "system prompt"},
             %{"role" => "user", "content" => "hello"},
             %{"role" => "assistant", "content" => "working", "tool_calls" => [tool_call]},
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "echoed: hi"}
           ] = body["messages"]

    assert tool_call == %{
             "id" => "call_1",
             "type" => "function",
             "function" => %{
               "name" => "froth_echo",
               "arguments" => ~s({"text":"hi"})
             },
             "extra_content" => %{"google" => %{"thought_signature" => "sig_123"}}
           }
  end

  test "build_request encodes neutral image blocks into OpenAI image_url parts" do
    request = %Request{
      provider: OpenAI,
      endpoint: "https://example.test/v1/chat/completions",
      headers: [{"authorization", "Bearer test"}],
      model: "gpt-5-mini",
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
            },
            "extra_content" => %{"openai" => %{"detail" => "high"}}
          }
        ])
      ]
    }

    {:ok, %{body: body}} = OpenAI.build_request(request)

    assert body["messages"] == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "What is in these images?"},
                 %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/png;base64,aGVsbG8="}
                 },
                 %{
                   "type" => "image_url",
                   "image_url" => %{
                     "url" => "https://example.test/cat.png",
                     "detail" => "high"
                   }
                 }
               ]
             }
           ]
  end
end
