defmodule Froth.ComicTest do
  use ExUnit.Case, async: true

  @messages [
    %{sender: "Ada & Lin", text: "Hello <everyone>! :)"},
    %{sender: "Mikael", text: "THIS IS GREAT!!!"}
  ]

  test "renders an inspectable SVG with escaped chat text" do
    assert {:ok, svg} = Froth.Comic.render_svg(@messages)
    assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
    assert svg =~ "@font-face"
    assert svg =~ "Ada &amp; Lin"
    assert svg =~ "Hello &lt;everyone&gt;! :)"
    refute svg =~ "Hello <everyone>"
  end

  @tag timeout: 30_000
  test "renders a PNG binary" do
    assert {:ok, <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>> = png} =
             Froth.Comic.render(@messages, width: 800)

    assert byte_size(png) > 10_000
  end
end
