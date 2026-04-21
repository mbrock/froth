defmodule Froth.Context.Blocks do
  @moduledoc """
  Operations on `Froth.Context.Block` lists.

  `materialize/1` is the only place in the system that decides
  whether a block's body gets inlined or externalized to a blob.
  Tools don't care; renderers don't care. This module is where the
  size threshold lives.

  ## Text-shaped vs binary-shaped blocks

  A block's `:mime` attr decides how its body is treated:

    * **Text-shaped** (no `:mime`, or a textual mime like `text/*`,
      `application/json`, `application/xml`): body is line-counted,
      and folded into a blob with `:head`/`:tail`/`:omitted` attrs
      when it exceeds the inline thresholds.

    * **Binary-shaped** (any other `:mime`, e.g. `image/jpeg`,
      `application/pdf`): body is stored to a blob unconditionally,
      and the block carries only structural attrs (`:blob`, `:size`,
      `:mime`). No line splitting, no head/tail — those don't apply
      to binary content.

  The binary path is what lets tools emit images, PDFs, etc. inside
  block trees instead of having to side-channel them as raw provider
  content blocks.

  ### Auto-promotion of non-JSON-safe text bodies

  A text-shaped body whose bytes aren't safe to persist as JSON text
  (invalid UTF-8, or an embedded NUL byte — Postgres refuses
  `\\u0000` inside JSONB) is promoted to a binary-shaped block before
  the usual split. `Froth.MimeSniff.sniff/1` looks at the leading
  bytes and picks a concrete MIME (e.g. `image/png`) when it
  recognizes the signature; otherwise the block is labeled
  `application/octet-stream`. In both cases the bytes go to a blob
  intact and the event row stays JSON-safe.

  The practical win is that tools don't have to know ahead of time
  whether their output is binary. A shell pipeline that prints a PNG
  just works — it surfaces to the LLM as an image content part — and
  a shell pipeline that dumps a core file just works too, landing in
  a blob as `application/octet-stream`.

  ## `:no_fold`

  Tools can force an otherwise-large text body to stay inline by
  setting the internal `:no_fold` attr. This is useful for deliberate
  reads such as pager slices, where re-folding would defeat the point
  of the tool call. `:no_fold` also keeps a binary-shaped block's
  body inline (skipping blob storage), for callers that want to hand
  the bytes directly to a downstream consumer.

  ## Pre-computed attrs

  For bodies that get blobbed, a set of pre-computed attrs is added
  to the block so renderers don't have to hit the database:

    * `:blob` — `"blob:<ulid>"` handle
    * `:size` — byte size of the full body
    * `:lines` — line count of the full body (text-shaped only)
    * `:head` — first N lines as a list (text-shaped only)
    * `:tail` — last N lines as a list (text-shaped only)
    * `:omitted` — lines not shown in head+tail (text-shaped only)

  `:size` / `:lines` are added even for inline bodies so the live
  renderer can decide whether to display them.
  """

  alias Froth.Blobs
  alias Froth.Context.Block
  alias Froth.MimeSniff

  @inline_max_bytes 2_400
  @inline_max_lines 80
  @head_lines 10
  @tail_lines 5
  @internal_attrs [:no_fold]
  @default_binary_mime "application/octet-stream"

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

  @doc """
  Whether a block carries non-textual binary content.

  Decided purely by the `:mime` attr; the body itself isn't
  inspected. Used by `materialize/1` to skip text math, and by
  downstream consumers (renderers, tool-result serialization) to
  know which blocks describe images/PDFs/audio/video.
  """
  @spec binary_shaped?(Block.t()) :: boolean()
  def binary_shaped?(%Block{attrs: attrs}),
    do: binary_mime?(Keyword.get(attrs, :mime))

  defp materialize_one(%Block{body: nil} = block) do
    block
    |> Map.put(:attrs, drop_internal_attrs(block.attrs))
    |> materialize_children()
  end

  defp materialize_one(%Block{body: body, attrs: attrs} = block)
       when is_binary(body) do
    cond do
      binary_mime?(Keyword.get(attrs, :mime)) ->
        materialize_binary(block, body, attrs)

      json_text_safe?(body) ->
        materialize_text(block, body, attrs)

      true ->
        # A text-shaped block came in carrying bytes that aren't safe
        # to persist as JSON text (invalid UTF-8, or an embedded NUL
        # byte that Postgres refuses inside JSONB). Rather than mangle
        # the payload with replacement characters, promote the block
        # to a binary-shaped one — sniffed down to a concrete MIME
        # when we can recognize the signature — and let the binary
        # path blob it. This is what lets a shell pipeline print a
        # PNG and have it surface as an actual image content part to
        # the LLM.
        sniffed_mime = MimeSniff.sniff(body) || @default_binary_mime
        promoted_attrs = Keyword.put(attrs, :mime, sniffed_mime)

        materialize_binary(
          %Block{block | attrs: promoted_attrs},
          body,
          promoted_attrs
        )
    end
  end

  defp materialize_text(%Block{} = block, body, attrs) do
    no_fold? = Keyword.get(attrs, :no_fold, false)
    attrs = drop_internal_attrs(attrs)
    trimmed = String.trim_trailing(body, "\n")
    size = byte_size(trimmed)
    line_count = count_lines(trimmed)

    if no_fold? or
         (size <= @inline_max_bytes and line_count <= @inline_max_lines) do
      block
      |> Map.put(:body, trimmed)
      |> Map.put(:attrs, put_text_facts(attrs, size, line_count))
      |> materialize_children()
    else
      {:ok, blob} =
        Blobs.put(trimmed, mime: Keyword.get(attrs, :mime, "text/plain"))

      all_lines = split_lines(trimmed)
      head = Enum.take(all_lines, min(@head_lines, line_count))
      tail_n = min(@tail_lines, max(line_count - length(head), 0))
      tail = Enum.drop(all_lines, line_count - tail_n)
      omitted = line_count - length(head) - tail_n

      new_attrs =
        attrs
        |> put_text_facts(size, line_count)
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

  defp materialize_binary(%Block{} = block, body, attrs) do
    no_fold? = Keyword.get(attrs, :no_fold, false)
    attrs = drop_internal_attrs(attrs)
    mime = Keyword.fetch!(attrs, :mime)
    size = byte_size(body)

    if no_fold? do
      block
      |> Map.put(:body, body)
      |> Map.put(:attrs, Keyword.put_new(attrs, :size, size))
      |> materialize_children()
    else
      {:ok, blob} = Blobs.put(body, mime: mime)

      new_attrs =
        attrs
        |> Keyword.put_new(:size, size)
        |> Keyword.put(:blob, blob.id)

      block
      |> Map.put(:body, nil)
      |> Map.put(:attrs, new_attrs)
      |> materialize_children()
    end
  end

  defp materialize_children(%Block{children: children} = block)
       when is_list(children) do
    %Block{block | children: Enum.map(children, &materialize_one/1)}
  end

  defp drop_internal_attrs(attrs) when is_list(attrs) do
    Keyword.drop(attrs, @internal_attrs)
  end

  defp put_text_facts(attrs, size, lines) do
    attrs
    |> Keyword.put_new(:size, size)
    |> Keyword.put_new(:lines, lines)
  end

  defp split_lines(""), do: []
  defp split_lines(bytes) when is_binary(bytes), do: String.split(bytes, "\n")

  defp count_lines(""), do: 0

  defp count_lines(bytes) when is_binary(bytes),
    do: length(split_lines(bytes))

  # Anything that isn't plain text or one of the textual structured
  # formats counts as binary for materialization purposes. The empty
  # / nil case is text-shaped (legacy default).
  defp binary_mime?(nil), do: false
  defp binary_mime?(""), do: false

  defp binary_mime?(mime) when is_binary(mime) do
    case String.downcase(mime)
         |> String.split(";", parts: 2)
         |> List.first()
         |> String.trim() do
      "text/" <> _ -> false
      "application/json" -> false
      "application/xml" -> false
      "application/xhtml+xml" -> false
      "application/javascript" -> false
      _ -> true
    end
  end

  defp binary_mime?(_), do: false

  @doc """
  Whether a binary is safe to persist as JSON text or in a Postgres
  `text` column.

  Returns true only for valid UTF-8 that contains no NUL bytes.
  Postgres rejects `\\u0000` inside JSON text columns and rejects NUL
  in `text`/`varchar` columns generally, even though NUL is legal
  UTF-8. Callers that see `false` here typically either promote to a
  binary-shaped block (so the bytes go to a blob) or substitute a
  human-readable placeholder (so event streams don't get truncated).
  """
  @spec json_text_safe?(binary() | any()) :: boolean()
  def json_text_safe?(body) when is_binary(body) do
    String.valid?(body) and not String.contains?(body, <<0>>)
  end

  def json_text_safe?(_), do: false
end
