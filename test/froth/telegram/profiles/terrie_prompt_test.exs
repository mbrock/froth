defmodule Froth.Telegram.Profiles.TerriePromptTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Profiles.TerriePrompt

  test "introduces Terrie through her own voice and role" do
    prompt = TerriePrompt.system_prompt(123, %{})

    assert prompt =~ "You are Terrie"
    assert prompt =~ "grounded,\nperceptive, and intellectually adventurous"
    assert prompt =~ "Talk with people, not at them"
    assert prompt =~ "@terraterriebot"
    assert prompt =~ "You run on GPT-5.6 Terra"
    assert prompt =~ "family's shared\nchronicle"
    assert prompt =~ "## Native capabilities"
    refute prompt =~ "You are not"
  end
end
