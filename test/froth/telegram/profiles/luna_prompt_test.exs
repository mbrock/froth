defmodule Froth.Telegram.Profiles.LunaPromptTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Profiles.LunaPrompt

  test "introduces Luna as independent from Charlie" do
    prompt = LunaPrompt.system_prompt(123, %{})

    assert prompt =~ "You are Luna"
    assert prompt =~ "You are not\nCharlie"
    assert prompt =~ "same shared chronicle"
    assert prompt =~ "## Native capabilities"
    refute prompt =~ "You are Charlie"
  end
end
