defmodule Froth.LLM.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message
  alias Froth.LLM.Providers.{OpenAI, OpenAIResponses}
  alias Froth.LLM.Request

  test "build_request delegates to the responses provider" do
    request = %Request{
      provider: OpenAI,
      endpoint: "https://example.test/v1/responses",
      headers: [{"authorization", "Bearer test"}],
      model: "gpt-5-mini",
      max_tokens: 1024,
      messages: [
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
        "text_verbosity" => "low"
      }
    }

    {:ok, delegated_request} = OpenAI.build_request(request)

    {:ok, direct_request} =
      OpenAIResponses.build_request(%{request | provider: OpenAIResponses})

    assert delegated_request == direct_request
    assert delegated_request.body["max_output_tokens"] == 1024
    assert delegated_request.body["reasoning"] == %{"effort" => "medium"}
    assert delegated_request.body["text"] == %{"verbosity" => "low"}
  end
end
