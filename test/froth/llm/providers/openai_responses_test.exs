defmodule Froth.LLM.Providers.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.{Message, Store}
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
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => "echoed: hi"
          }
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
      provider_options: %{
        "reasoning_effort" => "medium",
        "reasoning_summary" => "auto",
        "text_verbosity" => "low",
        "previous_response_id" => "resp_prev_123"
      }
    }

    {:ok, %{body: body}} = OpenAIResponses.build_request(request)

    assert body["model"] == "gpt-5.4"
    assert body["instructions"] == "system prompt"
    assert body["store"] == true
    assert body["max_output_tokens"] == 1024
    assert body["previous_response_id"] == "resp_prev_123"
    assert body["reasoning"] == %{"effort" => "medium", "summary" => "auto"}
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
             %{
               "type" => "function_call_output",
               "call_id" => "call_1",
               "output" => "echoed: hi"
             }
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
                 %{
                   "type" => "input_text",
                   "text" => "What is in these images?"
                 },
                 %{
                   "type" => "input_image",
                   "image_url" => "data:image/png;base64,aGVsbG8="
                 },
                 %{
                   "type" => "input_image",
                   "image_url" => "https://example.test/cat.png"
                 }
               ]
             }
           ]
  end

  test "decode_payload and finalize preserve the response id for continuation" do
    store = Store.new()

    {edits, done?} =
      OpenAIResponses.decode_payload(
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_123",
            "status" => "completed",
            "usage" => %{"input_tokens" => 11, "output_tokens" => 7}
          }
        },
        store
      )

    refute done?

    result =
      store
      |> Store.apply_edits(edits)
      |> OpenAIResponses.finalize()

    assert result.response_id == "resp_123"
    assert result.message_id == "resp_123"
    assert result.stop_reason == "end_turn"

    assert result.usage == %{
             "prompt_tokens" => 11,
             "completion_tokens" => 7,
             "total_tokens" => 18
           }
  end

  test "decode_payload captures streamed openai error events as provider errors" do
    {edits, done?} =
      OpenAIResponses.decode_payload(
        %{
          "type" => "error",
          "error" => %{
            "code" => "rate_limit_exceeded",
            "type" => "tokens",
            "message" => "Rate limit reached."
          }
        },
        Store.new()
      )

    assert done?

    store = Store.apply_edits(Store.new(), edits)

    assert Store.get(store, ["message", "error"]) == %{
             "error" => %{
               "code" => "rate_limit_exceeded",
               "type" => "tokens",
               "message" => "Rate limit reached."
             }
           }
  end

  test "decode_payload captures failed responses as provider errors" do
    {edits, done?} =
      OpenAIResponses.decode_payload(
        %{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_failed_123",
            "status" => "failed",
            "error" => %{
              "code" => "rate_limit_exceeded",
              "type" => "tokens",
              "message" => "Rate limit reached."
            }
          }
        },
        Store.new()
      )

    assert done?

    store = Store.apply_edits(Store.new(), edits)

    assert Store.get(store, ["message", "error"]) == %{
             "error" => %{
               "code" => "rate_limit_exceeded",
               "type" => "tokens",
               "message" => "Rate limit reached."
             },
             "response_id" => "resp_failed_123",
             "status" => "failed"
           }
  end

  test "decode_payload and finalize preserve reasoning summaries" do
    store = Store.new()

    {edits, done?} =
      OpenAIResponses.decode_payload(
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_456",
            "status" => "completed",
            "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
            "output" => [
              %{
                "type" => "reasoning",
                "summary" => [
                  %{
                    "type" => "summary_text",
                    "text" =>
                      "Checked the summaries and grouped the real same-day events."
                  }
                ]
              }
            ]
          }
        },
        store
      )

    refute done?

    summary_edit =
      Enum.find(edits, fn edit ->
        edit.resource == ["message"] and edit.path == ["reasoning_summary"]
      end)

    assert Froth.LLM.Edit.project_event(summary_edit) ==
             {:thinking_summary,
              %{
                "thinking" =>
                  "Checked the summaries and grouped the real same-day events."
              }}

    result =
      store
      |> Store.apply_edits(edits)
      |> OpenAIResponses.finalize()

    assert result.reasoning_summary ==
             "Checked the summaries and grouped the real same-day events."

    assert result.content == [
             %{
               "type" => "thinking",
               "thinking" =>
                 "Checked the summaries and grouped the real same-day events."
             }
           ]
  end
end
