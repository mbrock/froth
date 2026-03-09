defmodule Froth.LLM.Providers.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Providers.OpenAICompat
  alias Froth.LLM.Request
  alias Froth.LLM.Store

  test "build_request encodes system messages, tools, and tool results" do
    request = %Request{
      provider: OpenAICompat,
      endpoint: "https://example.test/v1/chat/completions",
      headers: [{"authorization", "Bearer test"}],
      model: "gpt-5-mini",
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
              "input" => %{"text" => "hi"}
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

    {:ok, %{body: body}} = OpenAICompat.build_request(request)

    assert body["model"] == "gpt-5-mini"
    assert body["max_tokens"] == 1024
    assert [%{"role" => "system", "content" => "system prompt"} | messages] = body["messages"]
    assert Enum.any?(messages, &(&1["role"] == "assistant" and &1["tool_calls"] != nil))
    assert Enum.any?(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "call_1"))
    assert [%{"type" => "function"}] = Enum.map(body["tools"], &Map.take(&1, ["type"]))
  end

  test "decodes streamed text deltas into neutral content" do
    store = Store.new()

    {edits_1, done_1} =
      OpenAICompat.decode_payload(
        %{
          "id" => "chatcmpl_1",
          "model" => "gpt-5-mini",
          "choices" => [%{"delta" => %{"content" => "Hel"}, "finish_reason" => nil}]
        },
        store
      )

    refute done_1
    store = Store.apply_edits(store, edits_1)

    {edits_2, done_2} =
      OpenAICompat.decode_payload(
        %{
          "id" => "chatcmpl_1",
          "model" => "gpt-5-mini",
          "choices" => [%{"delta" => %{"content" => "lo"}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2}
        },
        store
      )

    refute done_2
    result = store |> Store.apply_edits(edits_2) |> OpenAICompat.finalize()

    assert result.text == "Hello"
    assert result.stop_reason == "stop"
    assert result.usage["prompt_tokens"] == 10
    assert result.content == [%{"type" => "text", "text" => "Hello"}]
  end

  test "decodes streamed tool call deltas into neutral tool_use blocks" do
    store = Store.new()

    {edits_1, _done?} =
      OpenAICompat.decode_payload(
        %{
          "id" => "chatcmpl_2",
          "model" => "gpt-5-mini",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "froth_echo", "arguments" => "{\"text\":\""}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        },
        store
      )

    store = Store.apply_edits(store, edits_1)

    {edits_2, _done?} =
      OpenAICompat.decode_payload(
        %{
          "id" => "chatcmpl_2",
          "model" => "gpt-5-mini",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => "hi\"}"}}
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        },
        store
      )

    result = store |> Store.apply_edits(edits_2) |> OpenAICompat.finalize()

    assert result.stop_reason == "tool_calls"

    assert result.content == [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "hi"}
             }
           ]
  end
end
