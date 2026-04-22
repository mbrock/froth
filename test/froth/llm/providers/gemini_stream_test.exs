defmodule LLM.Providers.GeminiStreamTest do
  use ExUnit.Case, async: false

  alias LLM
  alias LLM.Message
  alias Req.Test, as: ReqTest

  test "stream_single sends Gemini web search grounding without nil response modalities" do
    stub_name = {:gemini_web_search, System.unique_integer([:positive])}
    previous_req_defaults = Req.default_options()

    on_exit(fn ->
      Req.default_options(previous_req_defaults)
    end)

    ReqTest.stub(stub_name, fn conn ->
      assert conn.body_params["model"] == "gemini-3.1-flash-lite-preview"

      assert conn.body_params["tools"] == [
               %{"type" => "google_search", "search_types" => ["web_search"]}
             ]

      refute Map.has_key?(conn.body_params, "response_modalities")

      sse =
        [
          ~s(data: {"event_type":"interaction.start","interaction":{"id":"resp_1","model":"gemini-3.1-flash-lite-preview","status":"in_progress"}}),
          ~s(data: {"event_type":"content.start","index":0,"content":{"type":"text"}}),
          ~s(data: {"event_type":"content.delta","index":0,"delta":{"type":"text","text":"hello"}}),
          ~s(data: {"event_type":"content.stop","index":0}),
          ~s(data: {"event_type":"interaction.complete","interaction":{"id":"resp_1","model":"gemini-3.1-flash-lite-preview","status":"completed","usage":{"total_input_tokens":1,"total_output_tokens":2,"total_tokens":3}}})
        ]
        |> Enum.map_join("\n\n", &"#{&1}\n")

      ReqTest.text(conn, sse)
    end)

    Req.default_options(plug: {ReqTest, stub_name})

    assert {:ok, result} =
             LLM.stream_single(
               [Message.user("search the web")],
               fn _event -> :ok end,
               provider: :gemini,
               model: "gemini-3.1-flash-lite-preview",
               api_key: "test-gemini",
               tools: [%{"type" => "web_search"}]
             )

    assert result.text == "hello"
    assert result.stop_reason == "stop"
  end
end
