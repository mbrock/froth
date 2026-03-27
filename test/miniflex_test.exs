defmodule MiniflexTest do
  use ExUnit.Case, async: true

  test "centers children on the main axis" do
    layout =
      Miniflex.row(
        [
          Miniflex.box([], id: :a, width: 4, height: 2),
          Miniflex.box([], id: :b, width: 4, height: 2)
        ],
        justify: :center
      )
      |> Miniflex.layout({14, 4})

    assert %{x: 3, y: 0, width: 4, height: 4} = find_layout(layout, :a).rect
    assert %{x: 7, y: 0, width: 4, height: 4} = find_layout(layout, :b).rect
  end

  test "distributes growth proportionally" do
    layout =
      Miniflex.row([
        Miniflex.box([], id: :a, width: 2, height: 1, grow: 1),
        Miniflex.box([], id: :b, width: 2, height: 1, grow: 2),
        Miniflex.box([], id: :c, width: 2, height: 1, grow: 1)
      ])
      |> Miniflex.layout({12, 3})

    assert 4 == find_layout(layout, :a).rect.width
    assert 5 == find_layout(layout, :b).rect.width
    assert 3 == find_layout(layout, :c).rect.width
  end

  test "align_self overrides container cross-axis alignment" do
    layout =
      Miniflex.row(
        [
          Miniflex.box([], id: :a, width: 4, height: 2, align_self: :center),
          Miniflex.box([], id: :b, width: 4, height: 2)
        ],
        align_items: :start
      )
      |> Miniflex.layout({12, 4})

    assert %{x: 0, y: 1, width: 4, height: 2} = find_layout(layout, :a).rect
    assert %{x: 4, y: 0, width: 4, height: 2} = find_layout(layout, :b).rect
  end

  test "accounts for borders padding and margins in child placement" do
    layout =
      Miniflex.row(
        [
          Miniflex.box([], id: :child, width: 2, height: 1, margin: %{left: 1, right: 1})
        ],
        border: 1,
        padding: 1
      )
      |> Miniflex.layout({12, 5})

    assert %{x: 2, y: 2, width: 8, height: 1} = layout.content_rect
    assert %{x: 3, y: 2, width: 2, height: 1} = find_layout(layout, :child).rect
  end

  test "wraps text and marks the final visible line with an ellipsis" do
    layout =
      Miniflex.column([
        Miniflex.text("alpha beta gamma",
          id: :text,
          width: 5,
          height: 2,
          wrap: :word,
          text_overflow: :ellipsis
        )
      ])
      |> Miniflex.layout({5, 2})

    text = find_layout(layout, :text).text

    assert ["alpha", "beta…"] == text.lines
    assert text.overflow?
    assert 3 == text.full_height
  end

  test "records content height and auto-scroll offset for vertical scroll containers" do
    layout =
      Miniflex.column(
        [
          Miniflex.box([], id: :a, height: 2, width: 4),
          Miniflex.box([], id: :b, height: 2, width: 4),
          Miniflex.box([], id: :c, height: 2, width: 4)
        ],
        overflow_y: :scroll
      )
      |> Miniflex.layout({4, 4})

    assert %{width: 4, height: 6} = layout.content_size
    assert 2 == layout.scroll_offset_y
    assert %{y: 4, height: 2} = find_layout(layout, :c).rect
  end

  defp find_layout(layout, id) do
    Enum.find(Miniflex.flatten(layout), &(&1.id == id))
  end
end
