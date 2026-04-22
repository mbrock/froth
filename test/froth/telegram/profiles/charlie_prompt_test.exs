defmodule Froth.Telegram.Profiles.CharliePromptTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Profiles.CharliePrompt

  test "reads system prompt from priv assets" do
    prompt = CharliePrompt.system_prompt(123, %{})

    assert prompt =~ "You are Charlie"
    assert prompt =~ "ghost uncle"
  end
end
