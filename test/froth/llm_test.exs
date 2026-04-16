defmodule Froth.LLMTest do
  use Froth.AnthropicCase, async: false

  alias Froth.ApiKey
  alias Froth.LLM
  alias Froth.Repo

  test "resolves provider names from provider refs and model prefixes" do
    assert :openai = LLM.resolve_provider_name(:openai, nil)
    assert :grok = LLM.resolve_provider_name("xai", nil)
    assert :gemini = LLM.resolve_provider_name(nil, "gemini-2.5-flash")
    assert :anthropic = LLM.resolve_provider_name(nil, "claude-opus-4-6")
  end

  test "loads the most recent API key for matching providers" do
    Repo.insert!(%ApiKey{
      name: "grok-old",
      provider: "xai",
      key: "old-key",
      inserted_at: ~U[2026-03-09 10:00:00Z]
    })

    Repo.insert!(%ApiKey{
      name: "grok-new",
      provider: "grok",
      key: "new-key",
      inserted_at: ~U[2026-03-09 10:05:00Z]
    })

    assert LLM.active_api_key(["grok", "xai"]) == "new-key"
    assert LLM.active_api_key(:grok) == "new-key"
    assert LLM.active_api_key(:gemini) == nil
  end

  test "defaults claude-opus-4-7 effort, max tokens, and thinking display" do
    test_pid = self()

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      send(test_pid, {:llm_request, request})

      {:ok,
       %{
         text: "ok",
         content: [%{"type" => "text", "text" => "ok"}],
         stop_reason: "end_turn",
         usage: %{},
         model: request.model,
         message_id: "msg_default_effort"
       }}
    end)

    assert {:ok, %{text: "ok"}} =
             LLM.stream_single(
               [LLM.Message.user("hello")],
               fn _event -> :ok end,
               api_key: "test-key",
               provider: :anthropic,
               model: "claude-opus-4-7"
             )

    assert_receive {:llm_request, request}
    assert request.output_config == %{"effort" => "xhigh"}
    assert request.max_tokens == 65_536
    assert request.thinking == %{"type" => "adaptive", "display" => "summarized"}
  end

  test "explicit claude effort overrides the claude-opus-4-7 default" do
    test_pid = self()

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      send(test_pid, {:llm_request, request})

      {:ok,
       %{
         text: "ok",
         content: [%{"type" => "text", "text" => "ok"}],
         stop_reason: "end_turn",
         usage: %{},
         model: request.model,
         message_id: "msg_explicit_effort"
       }}
    end)

    assert {:ok, %{text: "ok"}} =
             LLM.stream_single(
               [LLM.Message.user("hello")],
               fn _event -> :ok end,
               api_key: "test-key",
               provider: :anthropic,
               model: "claude-opus-4-7",
               effort: "high"
             )

    assert_receive {:llm_request, request}
    assert request.output_config == %{"effort" => "high"}
  end

  test "explicit max effort is preserved for claude-opus-4-7" do
    test_pid = self()

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      send(test_pid, {:llm_request, request})

      {:ok,
       %{
         text: "ok",
         content: [%{"type" => "text", "text" => "ok"}],
         stop_reason: "end_turn",
         usage: %{},
         model: request.model,
         message_id: "msg_max_effort"
       }}
    end)

    assert {:ok, %{text: "ok"}} =
             LLM.stream_single(
               [LLM.Message.user("hello")],
               fn _event -> :ok end,
               api_key: "test-key",
               provider: :anthropic,
               model: "claude-opus-4-7",
               effort: "max"
             )

    assert_receive {:llm_request, request}
    assert request.output_config == %{"effort" => "max"}
  end

  test "explicit thinking display is preserved for claude-opus-4-7" do
    test_pid = self()

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      send(test_pid, {:llm_request, request})

      {:ok,
       %{
         text: "ok",
         content: [%{"type" => "text", "text" => "ok"}],
         stop_reason: "end_turn",
         usage: %{},
         model: request.model,
         message_id: "msg_thinking_display"
       }}
    end)

    assert {:ok, %{text: "ok"}} =
             LLM.stream_single(
               [LLM.Message.user("hello")],
               fn _event -> :ok end,
               api_key: "test-key",
               provider: :anthropic,
               model: "claude-opus-4-7",
               thinking: %{"type" => "adaptive", "display" => "omitted"}
             )

    assert_receive {:llm_request, request}
    assert request.thinking == %{"type" => "adaptive", "display" => "omitted"}
  end
end
