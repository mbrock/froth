defmodule Froth.OpenAITest do
  use ExUnit.Case, async: false

  alias Froth.LLM.Request
  alias Froth.LLM.Providers.OpenAI, as: OpenAIProvider
  alias Froth.OpenAI

  setup do
    original_config = Application.get_env(:froth, OpenAI, [])
    original_stream_fun = Application.get_env(:froth, :llm_stream_fun)

    on_exit(fn ->
      Application.put_env(:froth, OpenAI, original_config)

      if is_nil(original_stream_fun) do
        Application.delete_env(:froth, :llm_stream_fun)
      else
        Application.put_env(:froth, :llm_stream_fun, original_stream_fun)
      end
    end)

    :ok
  end

  test "stream_single/3 uses the native OpenAI provider" do
    test_pid = self()

    Application.put_env(:froth, OpenAI,
      api_key: "test-key-not-real",
      model: "gpt-5-mini"
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
         message_id: "msg_test"
       }}
    end)

    assert {:ok, result} =
             OpenAI.stream_single(
               [%{"role" => "user", "content" => "hello"}],
               fn _event -> :ok end
             )

    assert result.text == "hello"

    assert_received {:llm_request,
                     %Request{
                       provider: OpenAIProvider,
                       endpoint: "https://api.openai.com/v1/chat/completions",
                       model: "gpt-5-mini",
                       messages: [%{"role" => "user", "content" => "hello"}],
                       provider_options: %{
                         "include_usage" => true,
                         "reasoning_effort" => nil
                       }
                     }}
  end
end
