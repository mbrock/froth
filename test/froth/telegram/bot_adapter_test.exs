defmodule Froth.Telegram.BotAdapterTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.BotAdapter

  test "Charlie keeps fuzzy name matching" do
    msg = text_message("hey charle")

    assert BotAdapter.mentioned?(msg, "charliebuddybot", 1, ["charlie"])
  end

  test "a non-Charlie bot does not inherit Charlie fuzzy matching" do
    msg = text_message("hey charle")

    refute BotAdapter.mentioned?(msg, "lunaluniebot", 2, ["luna"])
  end

  test "configured Luna names still trigger the bot" do
    msg = text_message("hey Luna")

    assert BotAdapter.mentioned?(msg, "lunaluniebot", 2, ["luna", "lulu"])
  end

  test "configured Terrie names trigger the bot" do
    msg = text_message("hey Terrie")

    assert BotAdapter.mentioned?(msg, "terraterriebot", 3, ["terrie", "terra"])
  end

  defp text_message(text) do
    %{"content" => %{"text" => %{"text" => text, "entities" => []}}}
  end
end
