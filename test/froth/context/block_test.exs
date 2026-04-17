defmodule Froth.Context.BlockTest do
  use ExUnit.Case, async: true

  alias Froth.Context.Block

  test "to_map/from_map roundtrips nested children" do
    block =
      Block.new(
        [kind: "timeline", id: "window-1"],
        nil,
        [
          Block.new([kind: "text", id: "tg:1"], "hello"),
          Block.new([kind: "analysis", id: 12], "short summary")
        ]
      )

    assert %Block{} = decoded = block |> Block.to_map() |> Block.from_map()

    assert decoded.attrs == [kind: "timeline", id: "window-1"]
    assert decoded.body == nil

    assert Enum.map(decoded.children, & &1.attrs) == [
             [kind: "text", id: "tg:1"],
             [kind: "analysis", id: 12]
           ]

    assert Enum.map(decoded.children, & &1.body) == ["hello", "short summary"]
  end

  test "from_map remains backward compatible with flat blocks" do
    assert %Block{} =
             decoded =
             Block.from_map(%{
               "shape" => "block",
               "attrs" => [%{"k" => "kind", "v" => "text"}],
               "body" => "hello"
             })

    assert decoded.attrs == [kind: "text"]
    assert decoded.body == "hello"
    assert decoded.children == []
  end
end
