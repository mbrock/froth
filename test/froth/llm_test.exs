defmodule Froth.LLMTest do
  use ExUnit.Case, async: true

  alias Froth.LLM

  test "resolves clients from provider names and model prefixes" do
    assert {:ok, Froth.OpenAI} = LLM.resolve_client_module(:openai, nil)
    assert {:ok, Froth.Grok} = LLM.resolve_client_module("xai", nil)
    assert {:ok, Froth.Gemini} = LLM.resolve_client_module(nil, "gemini-2.5-flash")
    assert {:ok, Froth.Anthropic} = LLM.resolve_client_module(nil, "claude-opus-4-6")
  end
end
