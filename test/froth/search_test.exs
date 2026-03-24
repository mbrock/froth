defmodule Froth.SearchTest do
  use ExUnit.Case, async: false

  alias Froth.LLM.Providers.{Gemini, OpenAIResponses, XAIResponses}
  alias Froth.Search

  setup do
    original_grok = Application.get_env(:froth, Froth.Grok, [])
    original_openai = Application.get_env(:froth, Froth.OpenAI, [])
    original_gemini = Application.get_env(:froth, Froth.Gemini, [])
    original_stream_fun = Application.get_env(:froth, :llm_stream_fun)
    original_stream_single_fun = Application.get_env(:froth, :llm_stream_single_fun)

    on_exit(fn ->
      Application.put_env(:froth, Froth.Grok, original_grok)
      Application.put_env(:froth, Froth.OpenAI, original_openai)
      Application.put_env(:froth, Froth.Gemini, original_gemini)

      if is_nil(original_stream_fun) do
        Application.delete_env(:froth, :llm_stream_fun)
      else
        Application.put_env(:froth, :llm_stream_fun, original_stream_fun)
      end

      if is_nil(original_stream_single_fun) do
        Application.delete_env(:froth, :llm_stream_single_fun)
      else
        Application.put_env(:froth, :llm_stream_single_fun, original_stream_single_fun)
      end
    end)

    :ok
  end

  test "query/2 fans out to providers and returns collated structured output" do
    Application.put_env(:froth, Froth.Grok, api_key: "test-grok")
    Application.put_env(:froth, Froth.OpenAI, api_key: "test-openai")
    Application.put_env(:froth, Froth.Gemini, api_key: "test-gemini")

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      result =
        case request.provider do
          XAIResponses ->
            "Grok says Kharg Island traffic slowed. Source: https://grok.example/report"

          OpenAIResponses ->
            "OpenAI confirms Kharg Island delays on 2026-03-24. https://openai.example/update"

          Gemini ->
            "Gemini reports tanker backups near Kharg Island. https://gemini.example/brief"
        end

      {:ok,
       %{
         text: result,
         content: [%{"type" => "text", "text" => result}],
         stop_reason: "stop",
         usage: %{},
         model: request.model,
         message_id: "resp_test"
       }}
    end)

    Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
      assert opts[:provider] == :anthropic
      [message] = api_messages
      assert message.role == :user

      json =
        ~s({"collated":"Two or more providers agree that Kharg Island shipping slowed, while details differ on severity.","agreement":0.75,"single_source_claims":["Only OpenAI included the exact date 2026-03-24."]})

      {:ok,
       %{
         text: json,
         content: [%{"type" => "text", "text" => json}],
         stop_reason: "end_turn",
         usage: %{},
         model: opts[:model],
         message_id: "msg_collate"
       }}
    end)

    assert {:ok, result} = Search.query("Kharg Island delays")

    assert result.query == "Kharg Island delays"
    assert result.collated =~ "Kharg Island shipping slowed"
    assert result.agreement == 0.75
    assert result.single_source_claims == ["Only OpenAI included the exact date 2026-03-24."]
    assert result.sources.grok.status == :ok
    assert result.sources.openai.status == :ok
    assert result.sources.gemini.status == :ok
    assert result.sources.grok.citations == ["https://grok.example/report"]
    assert result.sources.openai.citations == ["https://openai.example/update"]
    assert result.sources.gemini.citations == ["https://gemini.example/brief"]
  end
end
