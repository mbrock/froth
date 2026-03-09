defmodule Froth.LLMTest do
  use Froth.AnthropicCase, async: false

  alias Froth.ApiKey
  alias Froth.LLM
  alias Froth.Repo

  test "resolves clients from provider names and model prefixes" do
    assert {:ok, Froth.OpenAI} = LLM.resolve_client_module(:openai, nil)
    assert {:ok, Froth.Grok} = LLM.resolve_client_module("xai", nil)
    assert {:ok, Froth.Gemini} = LLM.resolve_client_module(nil, "gemini-2.5-flash")
    assert {:ok, Froth.Anthropic} = LLM.resolve_client_module(nil, "claude-opus-4-6")
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
end
