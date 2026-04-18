defmodule Froth.Context.Blocks do
  @moduledoc """
  Operations on `Froth.Context.Block` lists.

  `materialize/1` is the only place in the system that decides
  whether a block's body gets inlined or externalized to a blob.
  Tools don't care; renderers don't care. This module is where the
  size threshold lives.

  Tools can force an otherwise-large body to stay inline by setting
  the internal `:no_fold` attr. This is useful for deliberate reads
  such as pager slices, where re-folding would defeat the point of
  the tool call.

  For bodies that get blobbed, a set of pre-computed attrs is added
  to the block so renderers don't have to hit the database:

    * `:blob` — `"blob:<ulid>"` handle
    * `:size` — byte size of the full body
    * `:lines` — line count of the full body
    * `:head` — first N lines as a list
    * `:tail` — last N lines as a list
    * `:omitted` — lines not shown in head+tail

  `:size` / `:lines` are added even for inline bodies so the live
  renderer can decide whether to display them.
  """

  alias Froth.Blobs
  alias Froth.Context.Block

  @inline_max_bytes 2_400
  @inline_max_lines 80
  @head_lines 10
  @tail_lines 5
  @internal_attrs [:no_fold]

  @doc """
  Materialize a block list for persistence and rendering.

  For each block, either inline the body with size/lines attrs added,
  or externalize it to a blob and replace the body with nil, adding
  blob/head/tail attrs.

  Blocks with no body pass through unchanged except for attribute
  normalization.

  Returns a new list of `%Block{}`.
  """
  @spec materialize([Block.t()]) :: [Block.t()]
  def materialize(blocks) when is_list(blocks) do
    Enum.map(blocks, &materialize_one/1)
  end

  defp materialize_one(%Block{body: nil} = block), do: materialize_children(block)

  defp materialize_one(%Block{body: body, attrs: attrs} = block) when is_binary(body) do
    no_fold? = Keyword.get(attrs, :no_fold, false)
    attrs = drop_internal_attrs(attrs)
    trimmed = String.trim_trailing(body, "\n")
    size = byte_size(trimmed)
    line_count = count_lines(trimmed)

    if no_fold? or (size <= @inline_max_bytes and line_count <= @inline_max_lines) do
      block
      |> Map.put(:body, trimmed)
      |> Map.put(:attrs, put_facts(attrs, size, line_count))
      |> materialize_children()
    else
      {:ok, blob} = Blobs.put(trimmed, mime: Keyword.get(attrs, :mime, "text/plain"))

      all_lines = split_lines(trimmed)
      head = Enum.take(all_lines, min(@head_lines, line_count))
      tail_n = min(@tail_lines, max(line_count - length(head), 0))
      tail = Enum.drop(all_lines, line_count - tail_n)
      omitted = line_count - length(head) - tail_n

      new_attrs =
        attrs
        |> put_facts(size, line_count)
        |> Keyword.put(:blob, blob.id)
        |> Keyword.put(:head, head)
        |> Keyword.put(:tail, tail)
        |> Keyword.put(:omitted, omitted)

      block
      |> Map.put(:body, nil)
      |> Map.put(:attrs, new_attrs)
      |> materialize_children()
    end
  end

  defp materialize_children(%Block{children: children} = block) when is_list(children) do
    %Block{block | children: Enum.map(children, &materialize_one/1)}
  end

  defp drop_internal_attrs(attrs) when is_list(attrs) do
    Keyword.drop(attrs, @internal_attrs)
  end

  defp put_facts(attrs, size, lines) do
    attrs
    |> Keyword.put_new(:size, size)
    |> Keyword.put_new(:lines, lines)
  end

  defp split_lines(""), do: []
  defp split_lines(bytes) when is_binary(bytes), do: String.split(bytes, "\n")

  defp count_lines(""), do: 0
  defp count_lines(bytes) when is_binary(bytes), do: length(split_lines(bytes))
end
