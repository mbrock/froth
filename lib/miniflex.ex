defmodule Miniflex do
  @moduledoc """
  A compact flexbox-like layout engine for terminal UIs.

  This module is inspired by Mikael's Zig `miniflex` subsystem in `~/xtc`, but
  it is intentionally shaped as an idiomatic Elixir API focused on layout
  computation rather than terminal rendering.

  The core ideas mirror the original engine:

  - Trees of row/column containers
  - Border-box sizing with padding, margin, and borders
  - Stable `order` handling
  - `grow`-based main-axis expansion
  - `justify` and cross-axis alignment
  - Scroll metadata for vertical overflow containers
  - Text nodes that produce wrapped or truncated lines inside their content box

  `layout/2` and `layout/3` return a tree of positioned rectangles plus any
  prepared text lines, ready for a future terminal renderer.

  ## Example

      tree =
        Miniflex.column(
          [
            Miniflex.row(
              [
                Miniflex.text("Left", width: 4),
                Miniflex.text("Right", width: 5)
              ],
              justify: :space_between
            )
          ],
          border: 1,
          padding: 1
        )

      layout = Miniflex.layout(tree, {20, 6})
      layout.rect
      #=> %{x: 0, y: 0, width: 20, height: 6}

  """

  @type direction :: :row | :column
  @type justify ::
          :start | :end | :center | :space_between | :space_around | :space_evenly
  @type align :: :start | :end | :center | :stretch | :baseline
  @type overflow :: :visible | :hidden | :scroll
  @type wrap_mode :: :none | :word | :grapheme
  @type text_overflow :: :clip | :ellipsis
  @type edge_input ::
          non_neg_integer()
          | {non_neg_integer(), non_neg_integer()}
          | {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | keyword()
          | map()

  @type rect :: %{
          x: integer(),
          y: integer(),
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  @type t :: %__MODULE__{
          id: term(),
          kind: :box | :text,
          children: [t()],
          text: String.t() | nil,
          direction: direction(),
          justify: justify(),
          align_items: align(),
          align_self: align() | nil,
          grow: non_neg_integer(),
          order: integer(),
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          padding: edges(),
          margin: edges(),
          border: non_neg_integer(),
          gap: non_neg_integer(),
          overflow_x: overflow(),
          overflow_y: overflow(),
          wrap: wrap_mode(),
          text_overflow: text_overflow(),
          metadata: map()
        }

  @type edges :: %{
          top: non_neg_integer(),
          right: non_neg_integer(),
          bottom: non_neg_integer(),
          left: non_neg_integer()
        }

  @type layout :: %{
          id: term(),
          kind: :box | :text,
          layout_order: non_neg_integer(),
          node: t(),
          rect: rect(),
          content_rect: rect(),
          content_size: %{width: non_neg_integer(), height: non_neg_integer()},
          scroll_offset_y: non_neg_integer(),
          text:
            nil
            | %{
                lines: [String.t()],
                visible_width: non_neg_integer(),
                visible_height: non_neg_integer(),
                full_width: non_neg_integer(),
                full_height: non_neg_integer(),
                overflow?: boolean()
              },
          children: [layout()]
        }

  defstruct id: nil,
            kind: :box,
            children: [],
            text: nil,
            direction: :row,
            justify: :start,
            align_items: :stretch,
            align_self: nil,
            grow: 0,
            order: 0,
            width: nil,
            height: nil,
            padding: %{top: 0, right: 0, bottom: 0, left: 0},
            margin: %{top: 0, right: 0, bottom: 0, left: 0},
            border: 0,
            gap: 0,
            overflow_x: :visible,
            overflow_y: :visible,
            wrap: :word,
            text_overflow: :clip,
            metadata: %{}

  @doc """
  Builds a generic layout box.

  Strings inside `children` are automatically converted to text nodes.
  """
  @spec box([t() | String.t()], keyword()) :: t()
  def box(children \\ [], opts \\ []) when is_list(children) and is_list(opts) do
    %__MODULE__{
      kind: :box,
      children: Enum.map(children, &coerce_child/1),
      direction: fetch_option(opts, :direction, :row),
      justify: fetch_option(opts, :justify, :start),
      align_items: fetch_option(opts, :align_items, :stretch),
      align_self: Keyword.get(opts, :align_self),
      grow: normalize_non_negative(Keyword.get(opts, :grow, 0)),
      order: Keyword.get(opts, :order, 0),
      width: normalize_optional_size(Keyword.get(opts, :width)),
      height: normalize_optional_size(Keyword.get(opts, :height)),
      padding: normalize_edges(Keyword.get(opts, :padding, 0)),
      margin: normalize_edges(Keyword.get(opts, :margin, 0)),
      border: normalize_non_negative(Keyword.get(opts, :border, 0)),
      gap: normalize_non_negative(Keyword.get(opts, :gap, 0)),
      overflow_x: fetch_option(opts, :overflow_x, :visible),
      overflow_y: fetch_option(opts, :overflow_y, :visible),
      wrap: fetch_option(opts, :wrap, :word),
      text_overflow: fetch_option(opts, :text_overflow, :clip),
      id: Keyword.get(opts, :id),
      metadata: normalize_metadata(Keyword.get(opts, :metadata, %{}))
    }
  end

  @doc """
  Builds a row container.
  """
  @spec row([t() | String.t()], keyword()) :: t()
  def row(children \\ [], opts \\ []) do
    box(children, Keyword.put(opts, :direction, :row))
  end

  @doc """
  Builds a column container.
  """
  @spec column([t() | String.t()], keyword()) :: t()
  def column(children \\ [], opts \\ []) do
    box(children, Keyword.put(opts, :direction, :column))
  end

  @doc """
  Builds a text node.
  """
  @spec text(String.t(), keyword()) :: t()
  def text(content, opts \\ []) when is_binary(content) and is_list(opts) do
    %__MODULE__{
      kind: :text,
      text: content,
      direction: :row,
      justify: fetch_option(opts, :justify, :start),
      align_items: fetch_option(opts, :align_items, :stretch),
      align_self: Keyword.get(opts, :align_self),
      grow: normalize_non_negative(Keyword.get(opts, :grow, 0)),
      order: Keyword.get(opts, :order, 0),
      width: normalize_optional_size(Keyword.get(opts, :width)),
      height: normalize_optional_size(Keyword.get(opts, :height)),
      padding: normalize_edges(Keyword.get(opts, :padding, 0)),
      margin: normalize_edges(Keyword.get(opts, :margin, 0)),
      border: normalize_non_negative(Keyword.get(opts, :border, 0)),
      gap: 0,
      overflow_x: fetch_option(opts, :overflow_x, :visible),
      overflow_y: fetch_option(opts, :overflow_y, :visible),
      wrap: fetch_option(opts, :wrap, :word),
      text_overflow: fetch_option(opts, :text_overflow, :clip),
      id: Keyword.get(opts, :id),
      metadata: normalize_metadata(Keyword.get(opts, :metadata, %{}))
    }
  end

  @doc """
  Lays out a node tree within a container size tuple.

  The root node always fills the provided container.
  """
  @spec layout(t(), {non_neg_integer(), non_neg_integer()}) :: layout()
  def layout(%__MODULE__{} = node, {width, height}) do
    layout(node, width, height)
  end

  @doc """
  Lays out a node tree within a container width and height.
  """
  @spec layout(t(), non_neg_integer(), non_neg_integer()) :: layout()
  def layout(%__MODULE__{} = node, width, height)
      when is_integer(width) and width >= 0 and is_integer(height) and height >= 0 do
    do_layout(node, %{x: 0, y: 0, width: width, height: height}, 0)
  end

  @doc """
  Flattens a layout tree into a preorder list.
  """
  @spec flatten(layout()) :: [layout()]
  def flatten(layout) do
    [layout | Enum.flat_map(layout.children, &flatten/1)]
  end

  defp do_layout(%__MODULE__{} = node, rect, layout_order) do
    content_rect = inner_rect(node, rect)
    text_layout = maybe_prepare_text(node, content_rect)
    {children, content_size, scroll_offset_y} = layout_children(node, content_rect)

    %{
      id: node.id,
      kind: node.kind,
      layout_order: layout_order,
      node: node,
      rect: rect,
      content_rect: content_rect,
      content_size: merge_content_size(node, content_rect, content_size, text_layout),
      scroll_offset_y: scroll_offset_y,
      text: text_layout,
      children: children
    }
  end

  defp layout_children(%__MODULE__{kind: :text}, _content_rect) do
    {[], %{width: 0, height: 0}, 0}
  end

  defp layout_children(%__MODULE__{children: []}, _content_rect) do
    {[], %{width: 0, height: 0}, 0}
  end

  defp layout_children(%__MODULE__{} = node, content_rect) do
    child_max_height =
      if node.overflow_y == :scroll do
        nil
      else
        content_rect.height
      end

    measured_children =
      node.children
      |> Enum.with_index()
      |> Enum.map(fn {child, source_index} ->
        %{
          child: child,
          source_index: source_index,
          measured: intrinsic_size(child, content_rect.width, child_max_height)
        }
      end)
      |> Enum.sort_by(fn entry -> {entry.child.order, entry.source_index} end)
      |> Enum.with_index()
      |> Enum.map(fn {entry, layout_order} -> Map.put(entry, :layout_order, layout_order) end)

    main_available = main_extent(content_rect, node.direction)
    gap_total = node.gap * max(length(measured_children) - 1, 0)

    base_main =
      Enum.reduce(measured_children, gap_total, fn entry, total ->
        total + main_extent(entry.measured, node.direction) +
          main_margin(entry.child, node.direction)
      end)

    total_grow =
      Enum.reduce(measured_children, 0, fn entry, total -> total + entry.child.grow end)

    extra_space = main_available - base_main
    extra_by_layout = distribute_grow(max(extra_space, 0), total_grow, measured_children)

    distributed_growth =
      Enum.reduce(extra_by_layout, 0, fn {_order, extra}, total -> total + extra end)

    remaining_main = main_available - base_main - distributed_growth

    {leading_space, between_spaces} =
      justify_spacing(node.justify, remaining_main, length(measured_children), node.gap)

    {laid_out_reversed, _, content_main_extent, content_cross_extent} =
      Enum.reduce(measured_children, {[], leading_space, 0, 0}, fn entry,
                                                                   {acc, cursor, max_main,
                                                                    max_cross} ->
        child = entry.child
        measured = entry.measured
        extra_main = Map.get(extra_by_layout, entry.layout_order, 0)
        child_main = main_extent(measured, node.direction) + extra_main
        child_cross = cross_extent(measured, node.direction)
        main_start_margin = main_start_margin(child, node.direction)
        main_end_margin = main_end_margin(child, node.direction)
        cross_start_margin = cross_start_margin(child, node.direction)
        cross_end_margin = cross_end_margin(child, node.direction)

        main_origin = main_origin(content_rect, node.direction)
        cross_origin = cross_origin(content_rect, node.direction)

        cross_available =
          max(
            cross_extent(content_rect, node.direction) - cross_start_margin - cross_end_margin,
            0
          )

        cross_align = child.align_self || node.align_items
        cross_size = aligned_cross_size(cross_align, child_cross, cross_available)
        cross_offset = aligned_cross_offset(cross_align, cross_size, cross_available)

        child_rect =
          if node.direction == :row do
            %{
              x: main_origin + cursor + main_start_margin,
              y: cross_origin + cross_start_margin + cross_offset,
              width: child_main,
              height: cross_size
            }
          else
            %{
              x: cross_origin + cross_start_margin + cross_offset,
              y: main_origin + cursor + main_start_margin,
              width: cross_size,
              height: child_main
            }
          end

        child_layout = do_layout(child, child_rect, entry.layout_order)
        next_cursor = cursor + main_start_margin + child_main + main_end_margin
        trailing_space = Enum.at(between_spaces, entry.layout_order, 0)
        next_cursor = next_cursor + trailing_space

        child_main_end =
          cursor + main_start_margin + child_main + main_end_margin

        child_cross_end =
          cross_start_margin + cross_offset + cross_size + cross_end_margin

        {
          [Map.put(child_layout, :source_index, entry.source_index) | acc],
          next_cursor,
          max(max_main, child_main_end),
          max(max_cross, child_cross_end)
        }
      end)

    children =
      laid_out_reversed
      |> Enum.reverse()
      |> Enum.sort_by(& &1.source_index)
      |> Enum.map(&Map.delete(&1, :source_index))

    content_size =
      if node.direction == :row do
        %{width: max(content_main_extent, 0), height: max(content_cross_extent, 0)}
      else
        %{width: max(content_cross_extent, 0), height: max(content_main_extent, 0)}
      end

    scroll_offset_y =
      if node.overflow_y == :scroll do
        max(content_size.height - content_rect.height, 0)
      else
        0
      end

    {children, content_size, scroll_offset_y}
  end

  defp intrinsic_size(%__MODULE__{} = node, max_width, max_height) do
    horizontal_inset = horizontal_inset(node)
    vertical_inset = vertical_inset(node)

    explicit_inner_width =
      case node.width do
        nil -> nil
        width -> max(width - horizontal_inset, 0)
      end

    explicit_inner_height =
      case node.height do
        nil -> nil
        height -> max(height - vertical_inset, 0)
      end

    content_max_width = explicit_inner_width || shrink_limit(max_width, horizontal_inset)

    content_max_height =
      explicit_inner_height ||
        if node.overflow_y == :scroll do
          nil
        else
          shrink_limit(max_height, vertical_inset)
        end

    measured_content =
      case node.kind do
        :text ->
          measure_text(node, content_max_width, content_max_height)

        :box ->
          measure_children(node, content_max_width, content_max_height)
      end

    width =
      node.width ||
        clamp_size(measured_content.width + horizontal_inset, max_width)

    height =
      node.height ||
        clamp_size(measured_content.height + vertical_inset, max_height)

    %{width: width, height: height}
  end

  defp measure_children(%__MODULE__{children: []}, _max_width, _max_height) do
    %{width: 0, height: 0}
  end

  defp measure_children(%__MODULE__{} = node, max_width, max_height) do
    child_sizes =
      Enum.map(node.children, fn child ->
        intrinsic_size(child, max_width, max_height)
      end)

    gap_total = node.gap * max(length(child_sizes) - 1, 0)

    {width, height} =
      if node.direction == :row do
        total_width =
          Enum.reduce(Enum.zip(node.children, child_sizes), gap_total, fn {child, size}, total ->
            total + size.width + child.margin.left + child.margin.right
          end)

        max_height =
          Enum.reduce(Enum.zip(node.children, child_sizes), 0, fn {child, size}, best ->
            max(best, size.height + child.margin.top + child.margin.bottom)
          end)

        {total_width, max_height}
      else
        max_width =
          Enum.reduce(Enum.zip(node.children, child_sizes), 0, fn {child, size}, best ->
            max(best, size.width + child.margin.left + child.margin.right)
          end)

        total_height =
          Enum.reduce(Enum.zip(node.children, child_sizes), gap_total, fn {child, size}, total ->
            total + size.height + child.margin.top + child.margin.bottom
          end)

        {max_width, total_height}
      end

    %{width: clamp_size(width, max_width), height: clamp_size(height, max_height)}
  end

  defp maybe_prepare_text(%__MODULE__{kind: :text} = node, content_rect) do
    shape_text(node, content_rect.width, content_rect.height)
  end

  defp maybe_prepare_text(%__MODULE__{}, _content_rect), do: nil

  defp merge_content_size(%__MODULE__{kind: :text}, _content_rect, content_size, text_layout) do
    if text_layout do
      %{width: text_layout.full_width, height: text_layout.full_height}
    else
      content_size
    end
  end

  defp merge_content_size(%__MODULE__{}, _content_rect, content_size, _text_layout),
    do: content_size

  defp measure_text(%__MODULE__{} = node, max_width, max_height) do
    shaped = shape_text(node, max_width, max_height)

    %{
      width: clamp_size(shaped.full_width, max_width),
      height: clamp_size(shaped.full_height, max_height)
    }
  end

  defp shape_text(
         %__MODULE__{text: text, wrap: wrap, text_overflow: overflow} = _node,
         max_width,
         max_height
       ) do
    all_lines = text |> wrap_text(max_width, wrap) |> apply_width_limit(max_width, overflow)
    full_width = max_line_width(all_lines)
    full_height = length(all_lines)

    {visible_lines, hidden_lines?} =
      apply_height_limit(all_lines, max_height, max_width, overflow)

    %{
      lines: visible_lines,
      visible_width: max_line_width(visible_lines),
      visible_height: length(visible_lines),
      full_width: full_width,
      full_height: full_height,
      overflow?: hidden_lines? || full_height != length(visible_lines)
    }
  end

  defp wrap_text(text, max_width, wrap) do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(fn line ->
      wrap_line(line, max_width, wrap)
    end)
  end

  defp wrap_line(line, nil, _wrap), do: [line]
  defp wrap_line(line, _max_width, :none), do: [line]

  defp wrap_line(line, max_width, _wrap) when max_width <= 0 do
    if line == "", do: [""], else: [line]
  end

  defp wrap_line(line, max_width, :grapheme) do
    graphemes = String.graphemes(line)

    {lines_reversed, current, _current_width} =
      Enum.reduce(graphemes, {[], "", 0}, fn grapheme, {lines, current, current_width} ->
        grapheme_width = display_width(grapheme)

        cond do
          current == "" ->
            {lines, grapheme, grapheme_width}

          current_width + grapheme_width <= max_width ->
            {lines, current <> grapheme, current_width + grapheme_width}

          true ->
            {[current | lines], grapheme, grapheme_width}
        end
      end)

    lines =
      case current do
        "" -> Enum.reverse(lines_reversed)
        _ -> Enum.reverse([current | lines_reversed])
      end

    if lines == [], do: [""], else: lines
  end

  defp wrap_line(line, max_width, :word) do
    tokens =
      Regex.scan(~r/\S+\s*|\s+/u, line)
      |> List.flatten()

    {lines_reversed, current} =
      Enum.reduce(tokens, {[], ""}, fn token, {lines, current} ->
        token = if current == "", do: String.trim_leading(token), else: token

        cond do
          token == "" ->
            {lines, current}

          current == "" and display_width(token) > max_width ->
            split = wrap_line(String.trim(token), max_width, :grapheme)
            trailing = List.last(split)
            leading = Enum.drop(split, -1)
            {Enum.reverse(leading, lines), trailing}

          display_width(current <> token) <= max_width ->
            {lines, current <> token}

          true ->
            emitted = String.trim_trailing(current)
            next_token = String.trim_leading(token)

            cond do
              next_token == "" ->
                {prepend_if_present(lines, emitted), ""}

              display_width(next_token) <= max_width ->
                {prepend_if_present(lines, emitted), next_token}

              true ->
                split = wrap_line(next_token, max_width, :grapheme)
                trailing = List.last(split)
                leading = Enum.drop(split, -1)
                {Enum.reverse(leading, prepend_if_present(lines, emitted)), trailing}
            end
        end
      end)

    lines =
      case current do
        "" -> Enum.reverse(lines_reversed)
        _ -> Enum.reverse([String.trim_trailing(current) | lines_reversed])
      end

    if lines == [], do: [""], else: lines
  end

  defp apply_width_limit(lines, nil, _overflow), do: lines

  defp apply_width_limit(lines, max_width, overflow) do
    Enum.map(lines, fn line ->
      {limited, _truncated?} = limit_line(line, max_width, overflow)
      limited
    end)
  end

  defp apply_height_limit(lines, nil, _max_width, _overflow), do: {lines, false}
  defp apply_height_limit(_lines, 0, _max_width, _overflow), do: {[], true}

  defp apply_height_limit(lines, max_height, max_width, overflow) do
    if length(lines) <= max_height do
      {lines, false}
    else
      visible = Enum.take(lines, max_height)

      visible =
        if overflow == :ellipsis and max_height > 0 do
          last_index = max_height - 1
          List.update_at(visible, last_index, &append_ellipsis(&1, max_width))
        else
          visible
        end

      {visible, true}
    end
  end

  defp limit_line(line, nil, _overflow), do: {line, false}
  defp limit_line(_line, 0, :ellipsis), do: {"", true}
  defp limit_line(_line, 0, :clip), do: {"", true}

  defp limit_line(line, max_width, overflow) do
    width = display_width(line)

    if width <= max_width do
      {line, false}
    else
      case overflow do
        :clip -> {take_display_width(line, max_width), true}
        :ellipsis -> {append_ellipsis(line, max_width), true}
      end
    end
  end

  defp append_ellipsis(_line, 0), do: ""
  defp append_ellipsis(_line, 1), do: "…"

  defp append_ellipsis(line, max_width) do
    take_display_width(line, max_width - 1) <> "…"
  end

  defp take_display_width(_line, max_width) when max_width <= 0, do: ""

  defp take_display_width(line, max_width) do
    {parts, _width} =
      Enum.reduce_while(String.graphemes(line), {[], 0}, fn grapheme, {parts, width} ->
        grapheme_width = display_width(grapheme)

        if width + grapheme_width <= max_width do
          {:cont, {[grapheme | parts], width + grapheme_width}}
        else
          {:halt, {parts, width}}
        end
      end)

    parts |> Enum.reverse() |> Enum.join()
  end

  defp max_line_width(lines) do
    Enum.reduce(lines, 0, fn line, best -> max(best, display_width(line)) end)
  end

  defp display_width(text) when is_binary(text) do
    Enum.reduce(String.graphemes(text), 0, fn grapheme, width ->
      width + grapheme_cluster_width(grapheme)
    end)
  end

  defp grapheme_cluster_width(grapheme) do
    codepoints = String.to_charlist(grapheme)

    width =
      Enum.reduce(codepoints, 0, fn codepoint, acc ->
        acc + codepoint_width(codepoint)
      end)

    if Enum.any?(codepoints, &(&1 == 0x200D)) and width > 0 do
      2
    else
      width
    end
  end

  defp codepoint_width(codepoint)
       when codepoint == 0 or codepoint < 32 or (codepoint >= 0x7F and codepoint < 0xA0) do
    0
  end

  defp codepoint_width(codepoint) do
    cond do
      combining_codepoint?(codepoint) -> 0
      wide_codepoint?(codepoint) -> 2
      true -> 1
    end
  end

  defp combining_codepoint?(codepoint) do
    in_any_range?(codepoint, [
      0x0300..0x036F,
      0x0483..0x0489,
      0x0591..0x05BD,
      0x05BF..0x05BF,
      0x05C1..0x05C2,
      0x05C4..0x05C5,
      0x05C7..0x05C7,
      0x0610..0x061A,
      0x064B..0x065F,
      0x0670..0x0670,
      0x06D6..0x06DD,
      0x06DF..0x06E4,
      0x06E7..0x06E8,
      0x06EA..0x06ED,
      0x0711..0x0711,
      0x0730..0x074A,
      0x07A6..0x07B0,
      0x07EB..0x07F3,
      0x0816..0x0819,
      0x081B..0x0823,
      0x0825..0x0827,
      0x0829..0x082D,
      0x0859..0x085B,
      0x08D3..0x08E1,
      0x08E3..0x0902,
      0x093A..0x093C,
      0x0941..0x0948,
      0x094D..0x094D,
      0x0951..0x0957,
      0x0962..0x0963,
      0x0981..0x0981,
      0x09BC..0x09BC,
      0x09C1..0x09C4,
      0x09CD..0x09CD,
      0x0A01..0x0A02,
      0x0A3C..0x0A3C,
      0x0A41..0x0A42,
      0x0A47..0x0A48,
      0x0A4B..0x0A4D,
      0x0A51..0x0A51,
      0x0A70..0x0A71,
      0x0A75..0x0A75,
      0x0A81..0x0A82,
      0x0ABC..0x0ABC,
      0x0AC1..0x0AC5,
      0x0AC7..0x0AC8,
      0x0ACD..0x0ACD,
      0x0AE2..0x0AE3,
      0x0B01..0x0B01,
      0x0B3C..0x0B3C,
      0x0B3F..0x0B3F,
      0x0B41..0x0B44,
      0x0B4D..0x0B4D,
      0x0B56..0x0B56,
      0x0B62..0x0B63,
      0x0B82..0x0B82,
      0x0BC0..0x0BC0,
      0x0BCD..0x0BCD,
      0x0C00..0x0C00,
      0x0C04..0x0C04,
      0x0C3E..0x0C40,
      0x0C46..0x0C48,
      0x0C4A..0x0C4D,
      0x0C55..0x0C56,
      0x0C62..0x0C63,
      0x0C81..0x0C81,
      0x0CBC..0x0CBC,
      0x0CBF..0x0CBF,
      0x0CC6..0x0CC6,
      0x0CCC..0x0CCD,
      0x0CE2..0x0CE3,
      0x0D00..0x0D01,
      0x0D3B..0x0D3C,
      0x0D41..0x0D44,
      0x0D4D..0x0D4D,
      0x0D62..0x0D63,
      0x0DCA..0x0DCA,
      0x0DD2..0x0DD4,
      0x0DD6..0x0DD6,
      0x0E31..0x0E31,
      0x0E34..0x0E3A,
      0x0E47..0x0E4E,
      0x0EB1..0x0EB1,
      0x0EB4..0x0EBC,
      0x0EC8..0x0ECD,
      0x0F18..0x0F19,
      0x0F35..0x0F35,
      0x0F37..0x0F37,
      0x0F39..0x0F39,
      0x0F71..0x0F7E,
      0x0F80..0x0F84,
      0x0F86..0x0F87,
      0x0F8D..0x0F97,
      0x0F99..0x0FBC,
      0x0FC6..0x0FC6,
      0x102D..0x1030,
      0x1032..0x1037,
      0x1039..0x103A,
      0x103D..0x103E,
      0x1058..0x1059,
      0x105E..0x1060,
      0x1071..0x1074,
      0x1082..0x1082,
      0x1085..0x1086,
      0x108D..0x108D,
      0x109D..0x109D,
      0x135D..0x135F,
      0x1712..0x1714,
      0x1732..0x1734,
      0x1752..0x1753,
      0x1772..0x1773,
      0x17B4..0x17B5,
      0x17B7..0x17BD,
      0x17C6..0x17C6,
      0x17C9..0x17D3,
      0x17DD..0x17DD,
      0x180B..0x180D,
      0x1885..0x1886,
      0x18A9..0x18A9,
      0x1920..0x1922,
      0x1927..0x1928,
      0x1932..0x1932,
      0x1939..0x193B,
      0x1A17..0x1A18,
      0x1A56..0x1A56,
      0x1A58..0x1A5E,
      0x1A60..0x1A60,
      0x1A62..0x1A62,
      0x1A65..0x1A6C,
      0x1A73..0x1A7C,
      0x1A7F..0x1A7F,
      0x1AB0..0x1ACE,
      0x1B00..0x1B03,
      0x1B34..0x1B34,
      0x1B36..0x1B3A,
      0x1B3C..0x1B3C,
      0x1B42..0x1B42,
      0x1B6B..0x1B73,
      0x1B80..0x1B81,
      0x1BA2..0x1BA5,
      0x1BA8..0x1BA9,
      0x1BAB..0x1BAD,
      0x1BE6..0x1BE6,
      0x1BE8..0x1BE9,
      0x1BED..0x1BED,
      0x1BEF..0x1BF1,
      0x1C2C..0x1C33,
      0x1C36..0x1C37,
      0x1CD0..0x1CD2,
      0x1CD4..0x1CE0,
      0x1CE2..0x1CE8,
      0x1CED..0x1CED,
      0x1CF4..0x1CF4,
      0x1CF8..0x1CF9,
      0x1DC0..0x1DFF,
      0x20D0..0x20F0,
      0x2CEF..0x2CF1,
      0x2D7F..0x2D7F,
      0x2DE0..0x2DFF,
      0x302A..0x302F,
      0x3099..0x309A,
      0xA66F..0xA672,
      0xA674..0xA67D,
      0xA69E..0xA69F,
      0xA6F0..0xA6F1,
      0xA802..0xA802,
      0xA806..0xA806,
      0xA80B..0xA80B,
      0xA825..0xA826,
      0xA82C..0xA82C,
      0xA8C4..0xA8C5,
      0xA8E0..0xA8F1,
      0xA926..0xA92D,
      0xA947..0xA951,
      0xA980..0xA982,
      0xA9B3..0xA9B3,
      0xA9B6..0xA9B9,
      0xA9BC..0xA9BC,
      0xA9E5..0xA9E5,
      0xAA29..0xAA2E,
      0xAA31..0xAA32,
      0xAA35..0xAA36,
      0xAA43..0xAA43,
      0xAA4C..0xAA4C,
      0xAA7C..0xAA7C,
      0xAAB0..0xAAB0,
      0xAAB2..0xAAB4,
      0xAAB7..0xAAB8,
      0xAABE..0xAABF,
      0xAAC1..0xAAC1,
      0xAAEC..0xAAED,
      0xAAF6..0xAAF6,
      0xABE5..0xABE5,
      0xABE8..0xABE8,
      0xABED..0xABED,
      0xFB1E..0xFB1E,
      0xFE00..0xFE0F,
      0xFE20..0xFE2F
    ])
  end

  defp wide_codepoint?(codepoint) do
    in_any_range?(codepoint, [
      0x1100..0x115F,
      0x231A..0x231B,
      0x2329..0x232A,
      0x23E9..0x23EC,
      0x23F0..0x23F0,
      0x23F3..0x23F3,
      0x25FD..0x25FE,
      0x2614..0x2615,
      0x2648..0x2653,
      0x267F..0x267F,
      0x2693..0x2693,
      0x26A1..0x26A1,
      0x26AA..0x26AB,
      0x26BD..0x26BE,
      0x26C4..0x26C5,
      0x26CE..0x26CE,
      0x26D4..0x26D4,
      0x26EA..0x26EA,
      0x26F2..0x26F3,
      0x26F5..0x26F5,
      0x26FA..0x26FA,
      0x26FD..0x26FD,
      0x2705..0x2705,
      0x270A..0x270B,
      0x2728..0x2728,
      0x274C..0x274C,
      0x274E..0x274E,
      0x2753..0x2755,
      0x2757..0x2757,
      0x2795..0x2797,
      0x27B0..0x27B0,
      0x27BF..0x27BF,
      0x2B1B..0x2B1C,
      0x2B50..0x2B50,
      0x2B55..0x2B55,
      0x2E80..0x2FFB,
      0x3000..0x303E,
      0x3041..0xA4CF,
      0xAC00..0xD7A3,
      0xF900..0xFAFF,
      0xFE10..0xFE19,
      0xFE30..0xFE6B,
      0xFF01..0xFF60,
      0xFFE0..0xFFE6,
      0x1F004..0x1F004,
      0x1F0CF..0x1F0CF,
      0x1F18E..0x1F18E,
      0x1F191..0x1F19A,
      0x1F200..0x1F251,
      0x1F300..0x1FAFF,
      0x20000..0x3FFFD
    ])
  end

  defp in_any_range?(value, ranges) do
    Enum.any?(ranges, fn range -> value in range end)
  end

  defp justify_spacing(_justify, _remaining, 0, _gap), do: {0, []}

  defp justify_spacing(:start, _remaining, count, gap),
    do: {0, List.duplicate(gap, max(count - 1, 0))}

  defp justify_spacing(:end, remaining, count, gap),
    do: {remaining, List.duplicate(gap, max(count - 1, 0))}

  defp justify_spacing(:center, remaining, count, gap),
    do: {div(remaining, 2), List.duplicate(gap, max(count - 1, 0))}

  defp justify_spacing(:space_between, _remaining, count, _gap) when count <= 1 do
    {0, []}
  end

  defp justify_spacing(:space_between, remaining, count, gap) do
    between =
      distribute_slots(remaining, count - 1)
      |> Enum.map(&(&1 + gap))

    {0, between}
  end

  defp justify_spacing(:space_evenly, remaining, count, gap) do
    slots = distribute_slots(remaining, count + 1)
    leading = List.first(slots, 0)

    between =
      slots
      |> Enum.slice(1, max(count - 1, 0))
      |> Enum.map(&(&1 + gap))

    {leading, between}
  end

  defp justify_spacing(:space_around, remaining, count, gap) do
    half_slots = distribute_slots(remaining, count * 2)
    leading = List.first(half_slots, 0)

    between =
      if count <= 1 do
        []
      else
        for index <- 0..(count - 2) do
          Enum.at(half_slots, index * 2 + 1, 0) +
            Enum.at(half_slots, index * 2 + 2, 0) +
            gap
        end
      end

    {leading, between}
  end

  defp distribute_slots(_total, slot_count) when slot_count <= 0, do: []

  defp distribute_slots(total, slot_count) do
    base = div(total, slot_count)
    remainder = rem(total, slot_count)

    Enum.map(0..(slot_count - 1), fn index ->
      cond do
        remainder > 0 and index < remainder -> base + 1
        remainder < 0 and index < abs(remainder) -> base - 1
        true -> base
      end
    end)
  end

  defp distribute_grow(_available, total_grow, measured_children) when total_grow <= 0 do
    Map.new(measured_children, fn entry -> {entry.layout_order, 0} end)
  end

  defp distribute_grow(available, _total_grow, measured_children) when available <= 0 do
    Map.new(measured_children, fn entry -> {entry.layout_order, 0} end)
  end

  defp distribute_grow(available, total_grow, measured_children) do
    {base_allocations, remaining} =
      Enum.reduce(measured_children, {%{}, available}, fn entry, {acc, remaining} ->
        share = div(available * entry.child.grow, total_grow)
        {Map.put(acc, entry.layout_order, share), remaining - share}
      end)

    growable_orders =
      measured_children
      |> Enum.filter(&(&1.child.grow > 0))
      |> Enum.map(& &1.layout_order)

    distribute_remaining_grow(base_allocations, growable_orders, remaining, 0)
  end

  defp distribute_remaining_grow(allocations, _growable_orders, 0, _cursor), do: allocations
  defp distribute_remaining_grow(allocations, [], _remaining, _cursor), do: allocations

  defp distribute_remaining_grow(allocations, growable_orders, remaining, cursor) do
    order = Enum.at(growable_orders, rem(cursor, length(growable_orders)))
    delta = if remaining > 0, do: 1, else: -1

    allocations =
      Map.update!(allocations, order, fn current ->
        current + delta
      end)

    distribute_remaining_grow(allocations, growable_orders, remaining - delta, cursor + 1)
  end

  defp inner_rect(%__MODULE__{} = node, rect) do
    left = node.border + node.padding.left
    right = node.border + node.padding.right
    top = node.border + node.padding.top
    bottom = node.border + node.padding.bottom

    %{
      x: rect.x + min(rect.width, left),
      y: rect.y + min(rect.height, top),
      width: max(rect.width - left - right, 0),
      height: max(rect.height - top - bottom, 0)
    }
  end

  defp horizontal_inset(%__MODULE__{} = node) do
    node.padding.left + node.padding.right + node.border * 2
  end

  defp vertical_inset(%__MODULE__{} = node) do
    node.padding.top + node.padding.bottom + node.border * 2
  end

  defp shrink_limit(nil, _inset), do: nil
  defp shrink_limit(limit, inset), do: max(limit - inset, 0)

  defp clamp_size(size, nil), do: max(size, 0)
  defp clamp_size(size, limit), do: min(max(size, 0), limit)

  defp main_extent(%{width: width}, :row), do: width
  defp main_extent(%{height: height}, :column), do: height
  defp cross_extent(%{height: height}, :row), do: height
  defp cross_extent(%{width: width}, :column), do: width

  defp main_origin(%{x: x}, :row), do: x
  defp main_origin(%{y: y}, :column), do: y
  defp cross_origin(%{y: y}, :row), do: y
  defp cross_origin(%{x: x}, :column), do: x

  defp main_start_margin(%__MODULE__{margin: %{left: left}}, :row), do: left
  defp main_start_margin(%__MODULE__{margin: %{top: top}}, :column), do: top
  defp main_end_margin(%__MODULE__{margin: %{right: right}}, :row), do: right
  defp main_end_margin(%__MODULE__{margin: %{bottom: bottom}}, :column), do: bottom

  defp main_margin(node, direction),
    do: main_start_margin(node, direction) + main_end_margin(node, direction)

  defp cross_start_margin(%__MODULE__{margin: %{top: top}}, :row), do: top
  defp cross_start_margin(%__MODULE__{margin: %{left: left}}, :column), do: left
  defp cross_end_margin(%__MODULE__{margin: %{bottom: bottom}}, :row), do: bottom
  defp cross_end_margin(%__MODULE__{margin: %{right: right}}, :column), do: right

  defp aligned_cross_size(:stretch, _natural, available), do: available
  defp aligned_cross_size(:baseline, natural, available), do: min(natural, available)
  defp aligned_cross_size(_align, natural, available), do: min(natural, available)

  defp aligned_cross_offset(:center, size, available), do: div(max(available - size, 0), 2)
  defp aligned_cross_offset(:end, size, available), do: max(available - size, 0)
  defp aligned_cross_offset(:baseline, _size, _available), do: 0
  defp aligned_cross_offset(_align, _size, _available), do: 0

  defp coerce_child(%__MODULE__{} = node), do: node
  defp coerce_child(child) when is_binary(child), do: text(child)

  defp prepend_if_present(lines, ""), do: lines
  defp prepend_if_present(lines, value), do: [value | lines]

  defp normalize_edges(value) when is_integer(value) and value >= 0 do
    %{top: value, right: value, bottom: value, left: value}
  end

  defp normalize_edges({vertical, horizontal})
       when is_integer(vertical) and vertical >= 0 and is_integer(horizontal) and horizontal >= 0 do
    %{top: vertical, right: horizontal, bottom: vertical, left: horizontal}
  end

  defp normalize_edges({top, right, bottom, left})
       when is_integer(top) and top >= 0 and is_integer(right) and right >= 0 and
              is_integer(bottom) and bottom >= 0 and is_integer(left) and left >= 0 do
    %{top: top, right: right, bottom: bottom, left: left}
  end

  defp normalize_edges(value) when is_list(value) or is_map(value) do
    map = Enum.into(value, %{})
    x = Map.get(map, :x, 0)
    y = Map.get(map, :y, 0)

    %{
      top: normalize_non_negative(Map.get(map, :top, Map.get(map, :t, y))),
      right: normalize_non_negative(Map.get(map, :right, Map.get(map, :r, x))),
      bottom: normalize_non_negative(Map.get(map, :bottom, Map.get(map, :b, y))),
      left: normalize_non_negative(Map.get(map, :left, Map.get(map, :l, x)))
    }
  end

  defp normalize_edges(nil), do: %{top: 0, right: 0, bottom: 0, left: 0}

  defp normalize_optional_size(nil), do: nil
  defp normalize_optional_size(value), do: normalize_non_negative(value)

  defp normalize_non_negative(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative(value) when is_integer(value), do: max(value, 0)

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(nil), do: %{}

  defp fetch_option(opts, key, default) do
    Keyword.get(opts, key, default)
  end
end
