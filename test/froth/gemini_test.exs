defmodule Froth.GeminiTest do
  use ExUnit.Case, async: false

  alias Froth.Gemini
  alias Froth.LLM.Request
  alias Froth.LLM.Providers.Gemini, as: GeminiProvider

  setup do
    original_config = Application.get_env(:froth, Gemini, [])
    original_stream_fun = Application.get_env(:froth, :llm_stream_fun)

    on_exit(fn ->
      Application.put_env(:froth, Gemini, original_config)

      if is_nil(original_stream_fun) do
        Application.delete_env(:froth, :llm_stream_fun)
      else
        Application.put_env(:froth, :llm_stream_fun, original_stream_fun)
      end
    end)

    :ok
  end

  test "stream_single/3 uses the native Gemini provider" do
    test_pid = self()

    Application.put_env(:froth, Gemini,
      api_key: "test-key-not-real",
      model: "gemini-3-flash-preview"
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
             Gemini.stream_single(
               [%{"role" => "user", "content" => "hello"}],
               fn _event -> :ok end
             )

    assert result.text == "hello"

    assert_received {:llm_request,
                     %Request{
                       provider: GeminiProvider,
                       model: "gemini-3-flash-preview",
                       messages: [%{"role" => "user", "content" => "hello"}],
                       endpoint: endpoint
                     }}

    assert endpoint ==
             "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:streamGenerateContent?alt=sse&key=test-key-not-real"
  end
end
