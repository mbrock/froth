defmodule Froth.LLM.Providers.GeminiInteractionsTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.GeminiInteractions
  alias Froth.LLM.Request
  alias Froth.LLM.Store

  test "build_request encodes neutral media blocks, tool results, and response modalities" do
    request = %Request{
      provider: GeminiInteractions,
      endpoint: "https://example.test/v1beta/interactions?alt=sse&key=test",
      model: "gemini-3-pro-image-preview",
      system: "system prompt",
      max_tokens: 1024,
      response_modalities: [:image],
      messages: [
        Message.user([
          %{
            "type" => "image",
            "source" => %{
              "type" => "base64",
              "media_type" => "image/png",
              "data" => "aGVsbG8="
            }
          },
          %{"type" => "text", "text" => "Edit this into a poster."}
        ]),
        Message.assistant([
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "froth_echo",
            "input" => %{"text" => "hi"},
            "extra_content" => %{
              "google" => %{"thought_signature" => "sig_123"}
            }
          }
        ]),
        Message.user([
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => [%{"type" => "text", "text" => "echoed: hi"}]
          }
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
      ]
    }

    {:ok, %{body: body}} = GeminiInteractions.build_request(request)

    assert body["system_instruction"] == "system prompt"
    assert body["generation_config"]["max_output_tokens"] == 1024
    assert body["response_modalities"] == ["image"]

    assert body["tools"] == [
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

    assert [
             %{"role" => "user", "content" => user_content},
             %{"role" => "model", "content" => model_content},
             %{"role" => "user", "content" => tool_result_content}
           ] = body["input"]

    assert user_content == [
             %{
               "type" => "image",
               "data" => "aGVsbG8=",
               "mime_type" => "image/png"
             },
             %{"type" => "text", "text" => "Edit this into a poster."}
           ]

    assert model_content == [
             %{
               "type" => "function_call",
               "id" => "call_1",
               "name" => "froth_echo",
               "arguments" => %{"text" => "hi"},
               "signature" => "sig_123"
             }
           ]

    assert tool_result_content == [
             %{
               "type" => "function_result",
               "call_id" => "call_1",
               "name" => "froth_echo",
               "result" => [%{"type" => "text", "text" => "echoed: hi"}],
               "signature" => "sig_123"
             }
           ]
  end

  test "build_request expands web_search tools into Gemini grounding config" do
    request = %Request{
      provider: GeminiInteractions,
      endpoint: "https://example.test/v1beta/interactions?alt=sse&key=test",
      model: "gemini-3.1-flash-lite-preview",
      messages: [Message.user("search the web")],
      tools: [%{"type" => "web_search"}]
    }

    {:ok, %{body: body}} = GeminiInteractions.build_request(request)

    assert body["tools"] == [
             %{"type" => "google_search", "search_types" => ["web_search"]}
           ]
  end

  test "decodes streamed image and text outputs into neutral content blocks" do
    store = Store.new()

    {edits_1, done_1} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "interaction.start",
          "interaction" => %{
            "id" => "resp_1",
            "model" => "gemini-3-pro-image-preview",
            "status" => "in_progress"
          }
        },
        store
      )

    refute done_1
    store = Store.apply_edits(store, edits_1)

    {edits_2, done_2} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.start",
          "index" => 0,
          "content" => %{"type" => "image"}
        },
        store
      )

    refute done_2
    store = Store.apply_edits(store, edits_2)

    {edits_3, done_3} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.delta",
          "index" => 0,
          "delta" => %{
            "type" => "image",
            "mime_type" => "image/png",
            "data" => "aGVs"
          }
        },
        store
      )

    refute done_3
    store = Store.apply_edits(store, edits_3)

    {edits_4, done_4} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.delta",
          "index" => 0,
          "delta" => %{
            "type" => "image",
            "data" => "bG8=",
            "resolution" => "high"
          }
        },
        store
      )

    refute done_4
    store = Store.apply_edits(store, edits_4)

    {edits_5, done_5} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.stop",
          "index" => 0
        },
        store
      )

    refute done_5
    store = Store.apply_edits(store, edits_5)

    {edits_6, done_6} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.start",
          "index" => 1,
          "content" => %{"type" => "text"}
        },
        store
      )

    refute done_6
    store = Store.apply_edits(store, edits_6)

    {edits_7, done_7} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.delta",
          "index" => 1,
          "delta" => %{"type" => "text", "text" => "Poster-ready."}
        },
        store
      )

    refute done_7
    store = Store.apply_edits(store, edits_7)

    {edits_8, done_8} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.stop",
          "index" => 1
        },
        store
      )

    refute done_8
    store = Store.apply_edits(store, edits_8)

    {edits_9, done_9} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "interaction.complete",
          "interaction" => %{
            "id" => "resp_1",
            "model" => "gemini-3-pro-image-preview",
            "status" => "completed",
            "usage" => %{
              "total_input_tokens" => 12,
              "total_output_tokens" => 34,
              "total_cached_tokens" => 0,
              "total_tokens" => 46,
              "total_thought_tokens" => 5
            }
          }
        },
        store
      )

    refute done_9

    result =
      store
      |> Store.apply_edits(edits_9)
      |> GeminiInteractions.finalize()

    assert result.text == "Poster-ready."
    assert result.stop_reason == "stop"
    assert result.usage["input_tokens"] == 12
    assert result.usage["output_tokens"] == 34

    assert result.content == [
             %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => "aGVsbG8="
               },
               "extra_content" => %{"google" => %{"resolution" => "high"}}
             },
             %{"type" => "text", "text" => "Poster-ready."}
           ]
  end

  test "decodes streamed function calls into neutral tool_use blocks" do
    store = Store.new()

    {edits, done?} =
      GeminiInteractions.decode_payload(
        %{
          "event_type" => "content.delta",
          "index" => 0,
          "delta" => %{
            "type" => "function_call",
            "id" => "call_1",
            "name" => "froth_echo",
            "arguments" => %{"text" => "hi"},
            "signature" => "sig_123"
          }
        },
        store
      )

    refute done?

    result =
      store |> Store.apply_edits(edits) |> GeminiInteractions.finalize()

    open_edit = Enum.find(edits, &(&1.op == :open))
    close_edit = Enum.find(edits, &(&1.op == :close))

    assert open_edit.attrs["extra_content"] == %{
             "google" => %{"thought_signature" => "sig_123"}
           }

    assert close_edit.attrs["input"] == %{"text" => "hi"}

    assert result.content == [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "hi"},
               "extra_content" => %{
                 "google" => %{"thought_signature" => "sig_123"}
               }
             }
           ]
  end
end
