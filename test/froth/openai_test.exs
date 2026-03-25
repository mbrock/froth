defmodule Froth.OpenAITest do
  use ExUnit.Case, async: false

  alias Froth.ApiKey
  alias Froth.LLM.Message
  alias Froth.LLM.Providers.OpenAIResponses
  alias Froth.LLM.Request
  alias Froth.OpenAI
  alias Froth.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

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

  test "stream_single/3 uses the Responses provider for standard requests" do
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
         message_id: "resp_test"
       }}
    end)

    assert {:ok, result} =
             OpenAI.stream_single(
               [Message.user("hello")],
               fn _event -> :ok end
             )

    assert result.text == "hello"

    assert_received {:llm_request,
                     %Request{
                       provider: OpenAIResponses,
                       endpoint: "https://api.openai.com/v1/responses",
                       model: "gpt-5-mini",
                       messages: [
                         %Message{role: :user, content: [%{"type" => "text", "text" => "hello"}]}
                       ],
                       provider_options: %{
                         "include_usage" => true,
                         "reasoning_effort" => nil,
                         "text_verbosity" => nil,
                         "previous_response_id" => nil
                       }
                     }}
  end

  test "stream_single/3 keeps tools and effort on the Responses path" do
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
         message_id: "resp_test"
       }}
    end)

    assert {:ok, result} =
             OpenAI.stream_single(
               [Message.user("hello")],
               fn _event -> :ok end,
               tools: [%{"type" => "web_search_preview"}],
               effort: "low",
               verbosity: "high",
               previous_response_id: "resp_123"
             )

    assert result.text == "hello"

    assert_received {:llm_request,
                     %Request{
                       provider: OpenAIResponses,
                       endpoint: "https://api.openai.com/v1/responses",
                       model: "gpt-5-mini",
                       messages: [
                         %Message{role: :user, content: [%{"type" => "text", "text" => "hello"}]}
                       ],
                       tools: [%{"type" => "web_search_preview"}],
                       provider_options: %{
                         "include_usage" => true,
                         "reasoning_effort" => "low",
                         "text_verbosity" => "high",
                         "previous_response_id" => "resp_123"
                       }
                     }}
  end

  test "stream_single/3 retries retryable openai provider errors with exponential backoff" do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:froth, OpenAI,
      api_key: "test-key-not-real",
      model: "gpt-5-mini"
    )

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      attempt =
        Agent.get_and_update(counter, fn current ->
          {current, current + 1}
        end)

      send(test_pid, {:llm_request, attempt, request})

      case attempt do
        0 ->
          {:error,
           {:provider_error, "openai",
            %{
              "error" => %{
                "code" => "rate_limit_exceeded",
                "type" => "tokens",
                "message" => "Rate limit reached."
              }
            }, %{}}}

        _ ->
          {:ok,
           %{
             text: "hello after retry",
             content: [%{"type" => "text", "text" => "hello after retry"}],
             stop_reason: "stop",
             usage: %{},
             model: request.model,
             message_id: "resp_retry"
           }}
      end
    end)

    assert {:ok, result} =
             OpenAI.stream_single(
               [Message.user("hello")],
               fn _event -> :ok end,
               max_retries: 1,
               retry_base_ms: 0,
               retry_max_ms: 0
             )

    assert result.text == "hello after retry"
    assert_receive {:llm_request, 0, _request}, 5_000
    assert_receive {:llm_request, 1, _request}, 5_000
  end

  test "stream_single/3 prefers the database OpenAI key over app config" do
    test_pid = self()

    Repo.insert!(%ApiKey{
      name: "openai-db-test",
      provider: "openai",
      key: "db-key-not-real",
      inserted_at: ~U[2026-03-25 19:55:00Z]
    })

    Application.put_env(:froth, OpenAI,
      api_key: "config-key-not-real",
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
         message_id: "resp_test"
       }}
    end)

    assert {:ok, result} =
             OpenAI.stream_single(
               [Message.user("hello")],
               fn _event -> :ok end
             )

    assert result.text == "hello"

    assert_received {:llm_request,
                     %Request{
                       headers: headers
                     }}

    assert {"authorization", "Bearer db-key-not-real"} in headers
    refute {"authorization", "Bearer config-key-not-real"} in headers
  end
end
