defmodule Froth.Telegram.PromptCacheTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.PromptCache

  test "marks the last chapter and the block three positions before the end for anthropic models" do
    parts = [
      "<chapter name=\"ch01\">one</chapter>",
      "<chapter name=\"ch02\">two</chapter>",
      "<msg message_id=\"0\">zero</msg>",
      "<msg message_id=\"1\">hello</msg>",
      "<msg message_id=\"2\">world</msg>",
      "<info>chat info</info>"
    ]

    blocks = PromptCache.text_blocks(parts, %{model: "claude-opus-4-6"})

    assert Enum.at(blocks, 0) == %{
             "type" => "text",
             "text" => Enum.at(parts, 0)
           }

    assert Enum.at(blocks, 1) == %{
             "type" => "text",
             "text" => Enum.at(parts, 1),
             "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
           }

    assert Enum.at(blocks, 2) == %{
             "type" => "text",
             "text" => Enum.at(parts, 2),
             "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
           }
  end

  test "does not add anthropic cache markers for non-anthropic models" do
    parts = [
      "<chapter name=\"ch01\">one</chapter>",
      "<msg message_id=\"1\">hello</msg>"
    ]

    assert PromptCache.text_blocks(parts, %{model: "gpt-5"}) == [
             %{"type" => "text", "text" => Enum.at(parts, 0)},
             %{"type" => "text", "text" => Enum.at(parts, 1)}
           ]
  end

  test "marks only the tail breakpoint when there are no chapters" do
    parts = [
      "<msg message_id=\"1\">hello</msg>",
      "<msg message_id=\"2\">there</msg>",
      "<msg message_id=\"3\">general</msg>",
      "<info>chat info</info>"
    ]

    assert PromptCache.text_blocks(parts, %{model: "claude-opus-4-6"}) == [
             %{
               "type" => "text",
               "text" => Enum.at(parts, 0),
               "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
             },
             %{"type" => "text", "text" => Enum.at(parts, 1)},
             %{"type" => "text", "text" => Enum.at(parts, 2)},
             %{"type" => "text", "text" => Enum.at(parts, 3)}
           ]
  end
end
