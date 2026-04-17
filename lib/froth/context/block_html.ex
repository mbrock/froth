defmodule Froth.Context.BlockHTML do
  @moduledoc """
  HEEx components that render `Froth.Context.Block` lists into the
  pseudo-XML the LLM sees.

  Two views, same data:

    * `.live/1` — used while a cycle is running (constructs
      `tool_result.content` for the next LLM turn). Rich: full inline
      body if present, else blob-backed head/tail. The agent needs
      enough information here to make the next move.

    * `.trace/1` — used when a past cycle is being shown inside a
      subsequent `<cycle>` block under an older `<msg>`. Compact: just
      attrs and a short preview. The agent has already acted on this
      block's data; the trace view is for *remembering what happened*,
      not for doing more work with it.

  Neither component calls `Phoenix.HTML.raw/1`. Text is escaped by
  HEEx. No strings are hand-built.
  """

  use Phoenix.Component

  alias Froth.Context.Block

  @preview_chars 120

  # ── live ─────────────────────────────────────────────────────────

  attr :blocks, :list, required: true

  def live(assigns) do
    ~H"""
    <.live_block :for={block <- @blocks} block={block} />
    """
  end

  attr :block, Block, required: true

  defp live_block(assigns) do
    ~H"""
    <.block_tag kind={kind(@block)} attrs={structural_attrs(@block)}>
      <%= cond do %>
        <% is_binary(@block.body) -> %>
          {@block.body}
        <% has_fold?(@block) -> %>
          <head lines={head_range(@block)}>{join(Block.attr(@block, :head, []))}</head>
          <omitted :if={Block.attr(@block, :omitted, 0) > 0} count={Block.attr(@block, :omitted)}>
            {Block.attr(@block, :omitted)} lines omitted — use pager to read more
          </omitted>
          <tail :if={Block.attr(@block, :tail, []) != []} lines={tail_range(@block)}>
            {join(Block.attr(@block, :tail, []))}
          </tail>
        <% true -> %>
      <% end %>
    </.block_tag>
    """
  end

  # ── trace ────────────────────────────────────────────────────────

  attr :blocks, :list, required: true

  def trace(assigns) do
    ~H"""
    <.trace_block :for={block <- @blocks} block={block} />
    """
  end

  attr :block, Block, required: true

  defp trace_block(assigns) do
    assigns = assign(assigns, preview: preview_text(assigns.block))

    ~H"""
    <.block_tag kind={kind(@block)} attrs={structural_attrs(@block)}>
      {@preview}
    </.block_tag>
    """
  end

  # ── shared ───────────────────────────────────────────────────────

  # The outer tag is named after the block's `kind` attr when it's a
  # safe identifier; otherwise falls back to a generic `<block>`. This
  # lets shells render as `<shell …>`, tasks as `<task …>`, etc.
  # without allowing arbitrary tag names through.
  attr :kind, :string, required: true
  attr :attrs, :list, required: true
  slot :inner_block

  defp block_tag(assigns) do
    assigns = assign(assigns, tag: safe_tag(assigns.kind))

    ~H"""
    <.dynamic_tag tag_name={@tag} {@attrs}>{render_slot(@inner_block)}</.dynamic_tag>
    """
  end

  defp kind(%Block{} = block), do: to_string(Block.attr(block, :kind) || "block")

  defp safe_tag(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name) and
         name not in ~w(head input command meta link base br hr img source track col embed wbr param) do
      name
    else
      "block"
    end
  end

  # Attrs rendered on the outer tag — everything except the fold
  # internals (head/tail/omitted are already expressed structurally
  # via child elements in the live view).
  @internal_fold_keys [:head, :tail, :omitted]

  defp structural_attrs(%Block{attrs: attrs}) do
    attrs
    |> Enum.reject(fn {k, v} ->
      k in [:kind | @internal_fold_keys] or is_nil(v) or v == "" or v == []
    end)
    |> Enum.map(fn {k, v} -> {to_string(k), to_attr_string(v)} end)
  end

  defp to_attr_string(v) when is_binary(v), do: v
  defp to_attr_string(v) when is_integer(v) or is_boolean(v), do: to_string(v)
  defp to_attr_string(v) when is_list(v), do: Enum.join(v, ",")
  defp to_attr_string(v), do: to_string(v)

  defp has_fold?(%Block{} = block) do
    is_binary(Block.attr(block, :blob)) or Block.attr(block, :head, []) != []
  end

  defp head_range(%Block{} = block) do
    case Block.attr(block, :head, []) do
      [] -> "0"
      head -> "1-#{length(head)}"
    end
  end

  defp tail_range(%Block{} = block) do
    tail = Block.attr(block, :tail, [])
    total = Block.attr(block, :lines, 0)
    n = length(tail)

    cond do
      n == 0 or total == 0 -> "0"
      true -> "#{max(total - n + 1, 1)}-#{total}"
    end
  end

  defp join(lines) when is_list(lines), do: Enum.join(lines, "\n")
  defp join(_), do: ""

  # A short, single-line preview string for the trace view.
  defp preview_text(%Block{body: body}) when is_binary(body) and body != "" do
    body
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, @preview_chars)
  end

  defp preview_text(%Block{} = block) do
    case Block.attr(block, :head, []) do
      [first | _] -> first |> String.slice(0, @preview_chars)
      _ -> ""
    end
  end

  # ── rendering helper ─────────────────────────────────────────────

  @doc """
  Render block list via `.live/1` to its canonical string form (what
  ends up in `tool_result.content`).
  """
  @spec live_to_string([Block.t()]) :: String.t()
  def live_to_string(blocks) when is_list(blocks) do
    %{blocks: blocks}
    |> live()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> String.trim()
  end
end
