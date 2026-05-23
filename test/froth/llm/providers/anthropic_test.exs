defmodule LLM.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias LLM.Message
  alias LLM.Providers.Anthropic
  alias LLM.Request

  test "build_request encodes normalized messages and preserves anthropic blocks" do
    request = %Request{
      provider: Anthropic,
      headers: [{"x-api-key", "test"}],
      model: "claude-opus-4-6",
      system: "system prompt",
      max_tokens: 1024,
      thinking: %{"type" => "enabled", "budget_tokens" => 256},
      output_config: %{"effort" => "medium"},
      cache_control: %{"type" => "ephemeral"},
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
      messages: [
        Message.system("ignored inline system"),
        Message.user([
          %{"type" => "text", "text" => "hello"},
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => "echoed: hi"
          }
        ]),
        Message.assistant([
          %{
            "type" => "thinking",
            "thinking" => "considering",
            "signature" => "sig_123"
          },
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "froth_echo",
            "input" => %{"text" => "hi"}
          }
        ])
      ]
    }

    {:ok, %{body: body, url: url}} = Anthropic.build_request(request)

    assert url == "https://api.anthropic.com/v1/messages"
    assert body["system"] == "system prompt"
    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 256}
    assert body["output_config"] == %{"effort" => "medium"}
    assert body["cache_control"] == %{"type" => "ephemeral"}
    assert [%{"name" => "froth_echo"}] = body["tools"]

    assert body["messages"] == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "hello"},
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "call_1",
                   "content" => "echoed: hi"
                 }
               ]
             },
             %{
               "role" => "assistant",
               "content" => [
                 %{
                   "type" => "thinking",
                   "thinking" => "considering",
                   "signature" => "sig_123"
                 },
                 %{
                   "type" => "tool_use",
                   "id" => "call_1",
                   "name" => "froth_echo",
                   "input" => %{"text" => "hi"}
                 }
               ]
             }
           ]
  end

  test "build_request preserves neutral image and document source blocks" do
    request = %Request{
      provider: Anthropic,
      headers: [{"x-api-key", "test"}],
      model: "claude-opus-4-6",
      system: "system prompt",
      max_tokens: 1024,
      messages: [
        Message.user([
          %{
            "type" => "image",
            "source" => %{
              "type" => "url",
              "url" => "https://example.test/cat.jpg"
            }
          },
          %{
            "type" => "document",
            "source" => %{
              "type" => "base64",
              "media_type" => "application/pdf",
              "data" => "JVBERi0xLjQK"
            }
          },
          %{"type" => "text", "text" => "Compare the image and the PDF."}
        ])
      ]
    }

    {:ok, %{body: body}} = Anthropic.build_request(request)

    assert body["messages"] == [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "url",
                     "url" => "https://example.test/cat.jpg"
                   }
                 },
                 %{
                   "type" => "document",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "application/pdf",
                     "data" => "JVBERi0xLjQK"
                   }
                 },
                 %{
                   "type" => "text",
                   "text" => "Compare the image and the PDF."
                 }
               ]
             }
           ]
  end

  test "build_request normalizes tool_result content to anthropic-compatible shapes" do
    request = %Request{
      provider: Anthropic,
      headers: [{"x-api-key", "test"}],
      model: "claude-opus-4-6",
      max_tokens: 1024,
      messages: [
        Message.user([
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_map",
            "content" => %{"status" => "ok", "answer" => 42}
          },
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_block",
            "content" => %{"type" => "text", "text" => "done"}
          }
        ])
      ]
    }

    {:ok, %{body: body}} = Anthropic.build_request(request)

    [message] = body["messages"]
    [map_result, block_result] = message["content"]

    assert message["role"] == "user"
    assert map_result["type"] == "tool_result"
    assert map_result["tool_use_id"] == "call_map"

    assert Jason.decode!(map_result["content"]) == %{
             "answer" => 42,
             "status" => "ok"
           }

    assert block_result == %{
             "type" => "tool_result",
             "tool_use_id" => "call_block",
             "content" => [%{"type" => "text", "text" => "done"}]
           }
  end

  test "build_request preserves long pager tool results in later same-cycle turns" do
    long_page =
      Enum.map_join(1..241, "\n", fn line ->
        "line #{line} #{String.duplicate("x", 80)}"
      end)

    request = %Request{
      provider: Anthropic,
      headers: [{"x-api-key", "test"}],
      model: "claude-opus-4-7",
      system: "system prompt",
      max_tokens: 1024,
      messages: [
        Message.user("read long output"),
        Message.assistant([
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "pager",
            "input" => %{"id" => "blob:01K", "lines" => 241}
          }
        ]),
        Message.user([
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => long_page
          }
        ]),
        Message.assistant([
          %{
            "type" => "tool_use",
            "id" => "call_2",
            "name" => "froth_echo",
            "input" => %{"text" => "inspect previous result"}
          }
        ])
      ]
    }

    {:ok, %{body: body}} = Anthropic.build_request(request)

    assert [
             _initial,
             _tool_call,
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "call_1",
                   "content" => encoded_content
                 }
               ]
             },
             _next_tool_call
           ] = body["messages"]

    assert encoded_content =~ "line 1 "
    assert encoded_content =~ "line 241 "
    refute encoded_content =~ "<omitted"
    refute encoded_content =~ "use pager to read more"
  end
end
