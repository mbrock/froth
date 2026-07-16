defmodule Froth.Comic.LayoutTest do
  use ExUnit.Case, async: true

  alias Froth.Comic.Layout

  test "a repeated speaker advances to a new panel" do
    messages = [
      %{sender: "Ada", text: "First"},
      %{sender: "Lin", text: "Second"},
      %{sender: "Ada", text: "Third"}
    ]

    assert {:ok, %{panels: [first, second]}} = Layout.layout(messages)
    assert Enum.map(first.balloons, & &1.sender) == ["Ada", "Lin"]
    assert Enum.map(second.balloons, & &1.sender) == ["Ada"]
  end

  test "dramatic single-message panels span the grid" do
    messages = [
      %{sender: "Ada", text: "A calm opening"},
      %{sender: "Ada", text: "THIS CHANGES EVERYTHING!!!"}
    ]

    assert {:ok, %{width: 1200, panels: [_first, dramatic]}} =
             Layout.layout(messages)

    assert dramatic.span == 2
    assert dramatic.width == 1160
    assert hd(dramatic.balloons).semantics.balloon == :shout
  end

  test "balloons and tails point to placed characters" do
    assert {:ok, %{panels: [panel]}} =
             Layout.layout([
               %{sender: "Ada", text: "Hello"},
               %{sender: "Lin", text: "Hi"}
             ])

    character_x = Map.new(panel.characters, &{&1.sender, &1.center_x})

    assert Enum.all?(panel.balloons, fn balloon ->
             balloon.speaker_x == Map.fetch!(character_x, balloon.sender) and
               balloon.x >= panel.x and
               balloon.x + balloon.width <= panel.x + panel.width
           end)
  end

  test "rejects malformed and empty input" do
    assert {:error, "comic requires at least one message"} = Layout.layout([])
    assert {:error, message} = Layout.layout([%{sender: "Ada", text: ""}])
    assert message =~ "message 0"
  end
end
