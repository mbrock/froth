defmodule Froth.GrokTest do
  use ExUnit.Case, async: false

  alias Froth.Grok
  alias Froth.LLM.Message
  alias Froth.LLM.Providers.XAIResponses
  alias Froth.LLM.Request

  setup do
    original_config = Application.get_env(:froth, Grok, [])
    original_stream_fun = Application.get_env(:froth, :llm_stream_fun)

    on_exit(fn ->
      Application.put_env(:froth, Grok, original_config)

      if is_nil(original_stream_fun) do
        Application.delete_env(:froth, :llm_stream_fun)
      else
        Application.put_env(:froth, :llm_stream_fun, original_stream_fun)
      end
    end)

    :ok
  end

  test "stream_single/3 uses the xAI Responses provider for built-in tools" do
    test_pid = self()

    Application.put_env(:froth, Grok,
      api_key: "test-key-not-real",
      model: "grok-4-1-fast-non-reasoning"
    )

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      send(test_pid, {:llm_request, request})

      {:ok,
       %{
         text: "hello",
         content: [%{"type" => "text", "text" => "hello"}],
         stop_reason: "stop",
         usage: %{},
         model: request.model,
         message_id: "resp_test"
       }}
    end)

    assert {:ok, result} =
             Grok.stream_single(
               [Message.user("hello")],
               fn _event -> :ok end,
               tools: [%{"type" => "web_search"}]
             )

    assert result.text == "hello"

    assert_received {:llm_request,
                     %Request{
                       provider: XAIResponses,
                       endpoint: "https://api.x.ai/v1/responses",
                       model: "grok-4-1-fast-non-reasoning",
                       messages: [
                         %Message{role: :user, content: [%{"type" => "text", "text" => "hello"}]}
                       ]
                     }}
  end
end
