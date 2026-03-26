defmodule Froth.Telegram.Profiles.LennartPromptTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Profiles.LennartPrompt

  test "default prompt tells Lennart to stay concise and keep recurring flavor rare" do
    prompt = LennartPrompt.system_prompt(123, %{bot_username: "barblebot"})

    assert prompt =~ "Default reply length: one short paragraph"
    assert prompt =~ "Write like you're being charged by the word."
    assert prompt =~ "Most replies should not mention Montreal, Quebec, or Jansen at all."
    assert prompt =~ "For news/current events, default to 2-4 sentences"
    assert prompt =~ "NORMAL MODE:"
  end

  test "link-trigger prompt adds an extra-short mode for URL reactions" do
    prompt =
      LennartPrompt.system_prompt(123, %{bot_username: "barblebot"}, %{
        "froth_meta" => %{"trigger" => "link_reactor"}
      })

    assert prompt =~ "LINK-TRIGGER MODE:"
    assert prompt =~ "1-2 sentences max."
    assert prompt =~ "Quick take only."
    assert prompt =~ "not by someone directly calling your name"
  end
end
