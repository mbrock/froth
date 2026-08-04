defmodule Froth.Telegram.Profiles.LunaPromptTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Profiles.LunaPrompt

  test "introduces Luna through her own voice and role" do
    prompt = LunaPrompt.system_prompt(123, %{})

    assert prompt =~ "You are Luna"
    assert prompt =~ "observant,\nintellectually curious, candid"
    assert prompt =~ "Talk with people, not at them"
    assert prompt =~ "You run on GPT-5.6 Luna"
    assert prompt =~ "family's shared\nchronicle"
    assert prompt =~ "## Native capabilities"
    refute prompt =~ "You are not Charlie"
  end
end
