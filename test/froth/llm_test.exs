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

  describe "build_request/2 defaults for claude-opus-4-7" do
    test "defaults effort, max tokens, and thinking display" do
      assert {:ok, request} =
               LLM.build_request(
                 [LLM.Message.user("hello")],
                 api_key: "test-key",
                 provider: :anthropic,
                 model: "claude-opus-4-7"
               )

      assert request.output_config == %{"effort" => "xhigh"}
      assert request.max_tokens == 65_536
      assert request.thinking == %{"type" => "adaptive", "display" => "summarized"}
    end

    test "explicit effort overrides the default" do
      assert {:ok, request} =
               LLM.build_request(
                 [LLM.Message.user("hello")],
                 api_key: "test-key",
                 provider: :anthropic,
                 model: "claude-opus-4-7",
                 effort: "high"
               )

      assert request.output_config == %{"effort" => "high"}
    end

    test "explicit max effort is preserved" do
      assert {:ok, request} =
               LLM.build_request(
                 [LLM.Message.user("hello")],
                 api_key: "test-key",
                 provider: :anthropic,
                 model: "claude-opus-4-7",
                 effort: "max"
               )

      assert request.output_config == %{"effort" => "max"}
    end

    test "explicit thinking display is preserved" do
      assert {:ok, request} =
               LLM.build_request(
                 [LLM.Message.user("hello")],
                 api_key: "test-key",
                 provider: :anthropic,
                 model: "claude-opus-4-7",
                 thinking: %{"type" => "adaptive", "display" => "omitted"}
               )

      assert request.thinking == %{"type" => "adaptive", "display" => "omitted"}
    end
  end
end
