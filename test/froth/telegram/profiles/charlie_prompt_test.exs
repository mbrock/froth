defmodule Froth.Telegram.Profiles.CharliePromptTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Profiles.CharliePrompt

  test "reads system prompt from priv assets" do
    prompt = CharliePrompt.system_prompt(123, %{})

    assert prompt =~ "You are Charlie"
    assert prompt =~ "ghost uncle"
  end

  test "presents live Elixir capability discovery as standing context" do
    prompt = CharliePrompt.system_prompt(123, %{})

    assert prompt =~ "## Native capabilities"
    assert prompt =~ "discover, inspect, act loop"
    assert prompt =~ ~s(action: "docs")
    assert prompt =~ "no targets"
    assert prompt =~ "include_source: true"
    assert prompt =~ "Froth.help(Module)"
    assert prompt =~ ~s(action: "eval")
    assert prompt =~ "Reuse a `session_id`"
    assert prompt =~ "evaluation can mutate the running system"
  end
end
