defmodule Froth.LLMTest do
  use Froth.AnthropicCase, async: true

  alias Froth.ApiKey
  alias Froth.ApiKeys
  alias Froth.Repo
  alias LLM

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

    assert ApiKeys.active_key(["grok", "xai"]) == "new-key"
    assert ApiKeys.active_key_for_provider(:grok) == "new-key"
    assert ApiKeys.active_key_for_provider(:gemini) == nil
  end

  describe "build_request/2" do
    test "requires an explicit provider" do
      assert {:error, :missing_provider} =
               LLM.build_request(
                 [LLM.Message.user("hello")],
                 api_key: "test-key",
                 model: "claude-opus-4-7"
               )
    end

    test "does not inject provider config defaults" do
      assert {:ok, request} =
               LLM.build_request(
                 [LLM.Message.user("hello")],
                 api_key: "test-key",
                 provider: :anthropic,
                 model: "claude-opus-4-7",
                 max_tokens: 4096,
                 system: "system prompt",
                 thinking: %{"type" => "adaptive", "display" => "omitted"},
                 effort: "high"
               )

      assert request.system == "system prompt"
      assert request.max_tokens == 4096
      assert request.output_config == %{"effort" => "high"}

      assert request.thinking == %{
               "type" => "adaptive",
               "display" => "omitted"
             }
    end
  end
end
