defmodule Froth.LLM.Providers.GeminiTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Providers.Gemini
  alias Froth.LLM.Request
  alias Froth.LLM.Store

  test "build_request encodes system messages, tools, function calls, and function responses" do
    request = %Request{
      provider: Gemini,
      endpoint:
        "https://example.test/v1beta/models/gemini-3-flash-preview:streamGenerateContent?alt=sse&key=test",
      model: "gemini-3-flash-preview",
      system: "system prompt",
      max_tokens: 1024,
      messages: [
        %{"role" => "user", "content" => "hello"},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "working"},
            %{
              "type" => "tool_use",
              "id" => "call_1",
              "name" => "froth_echo",
              "input" => %{"text" => "hi"},
              "extra_content" => %{"google" => %{"thought_signature" => "sig_123"}}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "echoed: hi"}
          ]
        }
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
      ]
    }

    {:ok, %{body: body}} = Gemini.build_request(request)

    assert body["systemInstruction"] == %{"parts" => [%{"text" => "system prompt"}]}
    assert body["generationConfig"]["maxOutputTokens"] == 1024
    assert [%{"functionDeclarations" => [%{"name" => "froth_echo"}]}] = body["tools"]

    assert [
             %{"role" => "user", "parts" => [%{"text" => "hello"}]},
             %{"role" => "model", "parts" => model_parts},
             %{"role" => "user", "parts" => [%{"functionResponse" => function_response}]}
           ] = body["contents"]

    assert [
             %{"text" => "working"},
             %{
               "functionCall" => %{
                 "id" => "call_1",
                 "name" => "froth_echo",
                 "args" => %{"text" => "hi"}
               },
               "thoughtSignature" => "sig_123"
             }
           ] = model_parts

    assert function_response == %{
             "id" => "call_1",
             "name" => "froth_echo",
             "response" => %{"result" => "echoed: hi"}
           }
  end

  test "decodes streamed text deltas into neutral content" do
    store = Store.new()

    {edits_1, done_1} =
      Gemini.decode_payload(
        %{
          "responseId" => "resp_1",
          "modelVersion" => "gemini-3-flash-preview",
          "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 1},
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "Hel"}]},
              "finishReason" => nil
            }
          ]
        },
        store
      )

    refute done_1
    store = Store.apply_edits(store, edits_1)

    {edits_2, done_2} =
      Gemini.decode_payload(
        %{
          "responseId" => "resp_1",
          "modelVersion" => "gemini-3-flash-preview",
          "usageMetadata" => %{"promptTokenCount" => 10, "candidatesTokenCount" => 2},
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "lo"}]},
              "finishReason" => "STOP"
            }
          ]
        },
        store
      )

    refute done_2
    result = store |> Store.apply_edits(edits_2) |> Gemini.finalize()

    assert result.text == "Hello"
    assert result.stop_reason == "stop"
    assert result.usage["input_tokens"] == 10
    assert result.usage["output_tokens"] == 2
    assert result.content == [%{"type" => "text", "text" => "Hello"}]
  end

  test "decodes streamed function calls into neutral tool_use blocks" do
    store = Store.new()

    {edits, done?} =
      Gemini.decode_payload(
        %{
          "responseId" => "resp_2",
          "modelVersion" => "gemini-3-flash-preview",
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{
                    "functionCall" => %{
                      "id" => "call_1",
                      "name" => "froth_echo",
                      "args" => %{"text" => "hi"}
                    },
                    "thoughtSignature" => "sig_123"
                  }
                ]
              },
              "finishReason" => "STOP"
            }
          ]
        },
        store
      )

    refute done?

    result = store |> Store.apply_edits(edits) |> Gemini.finalize()
    open_edit = Enum.find(edits, &(&1.op == :open))
    close_edit = Enum.find(edits, &(&1.op == :close))

    assert open_edit.attrs["extra_content"] == %{"google" => %{"thought_signature" => "sig_123"}}
    assert close_edit.attrs["input"] == %{"text" => "hi"}
    assert result.stop_reason == "stop"

    assert result.content == [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "hi"},
               "extra_content" => %{"google" => %{"thought_signature" => "sig_123"}}
             }
           ]
  end
end
