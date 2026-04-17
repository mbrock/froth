defmodule Froth.Blobs.Render do
  @moduledoc """
  Shared rendering of blob-backed tool returns into model-facing
  `<output>` frames.

  The rule:

    * Bodies below the inline threshold (≤ ~1200 bytes AND ≤ 48 lines)
      are rendered inline, no blob created.
    * Larger bodies are stored as a blob and rendered with a head
      window, an explicit `(N lines omitted — use pager …)` note, and
      a tail window — so the model always knows both ends of a thing
      and always has a handle to pull more.

  This module is the *only* place that decides what "fold" looks like
  for tool output. Callers pass structured attrs (kind, task_id, exit
  code, etc.); the frame is produced consistently.
  """

  alias Froth.Blobs

  @inline_max_bytes 1_200
  @inline_max_lines 48
  @default_head_lines 10
  @default_tail_lines 5

  @trace_inline_max_bytes 600
  @trace_inline_max_lines 20
  @trace_head_lines 6
  @trace_tail_lines 3

  @doc """
  Render a tool return body into an `<output>` frame, possibly storing
  the body as a blob.

  Options:
    * `:kind` — string kind label (required, e.g. `"shell"`, `"eval"`).
    * `:attrs` — extra keyword of structured attributes (task_id, exit
      code, mime, etc.) rendered on the open tag as `k="v"`. nil values
      are dropped.
    * `:head_lines`, `:tail_lines` — override window sizes.
    * `:inline_max_bytes`, `:inline_max_lines` — override the fold
      threshold.
    * `:force_blob` — always store as blob even if small (rarely needed;
      used by callers that want a stable handle for later reference).

  Returns `{:ok, text}` always. Errors from blob insert fall through
  to the inline rendering (we never lose output).
  """
  @spec tool_return(binary(), keyword()) :: {:ok, String.t()}
  def tool_return(body, opts \\ []) when is_binary(body) and is_list(opts) do
    kind = Keyword.fetch!(opts, :kind)
    attrs = Keyword.get(opts, :attrs, [])
    inline_max_bytes = Keyword.get(opts, :inline_max_bytes, @inline_max_bytes)
    inline_max_lines = Keyword.get(opts, :inline_max_lines, @inline_max_lines)
    head_lines = Keyword.get(opts, :head_lines, @default_head_lines)
    tail_lines = Keyword.get(opts, :tail_lines, @default_tail_lines)
    force_blob = Keyword.get(opts, :force_blob, false)

    trimmed = String.trim_trailing(body, "\n")
    size = byte_size(trimmed)
    line_count = count_lines(trimmed)

    inline? = not force_blob and size <= inline_max_bytes and line_count <= inline_max_lines

    if inline? do
      {:ok, render_inline(kind, attrs, trimmed, size, line_count)}
    else
      case Blobs.put(trimmed, mime: Keyword.get(attrs, :mime, "text/plain")) do
        {:ok, blob} ->
          {:ok, render_folded(kind, attrs, blob, trimmed, head_lines, tail_lines)}

        {:error, _reason} ->
          # Blob store is down — degrade gracefully by inlining the
          # truncated body with an explicit notice.
          {:ok, render_inline_truncated(kind, attrs, trimmed, size, line_count)}
      end
    end
  end

  @doc """
  Shape a historical tool return (from a past cycle) into something
  compact for the inline `<cycle>…<return>` view inside `<msg>` blocks.

  Rules:

    * If the text is already an `<output>` frame produced by
      `tool_return/2`, pass it through unchanged — it's already bounded.
    * Else, if the text is below the trace-inline threshold, return it
      trimmed.
    * Else, render the first few and last few lines with an explicit
      `(… N lines omitted — use read_tool_transcript or pager …)`
      note. No blob is created here; this is a view of already-persisted
      content.
  """
  @spec trace_return(binary()) :: String.t()
  def trace_return(text) when is_binary(text) do
    stripped = String.trim_trailing(text, "\n")

    cond do
      output_frame?(stripped) ->
        stripped

      compact?(stripped) ->
        stripped

      true ->
        fold_for_trace(stripped)
    end
  end

  def trace_return(_), do: ""

  @doc """
  True if `text` is an `<output>` frame produced by `tool_return/2`.
  Used by the trace renderer to pass structured frames through
  unescaped instead of wrapping them in `<return>`.
  """
  @spec output_frame?(any()) :: boolean()
  def output_frame?(text) when is_binary(text) do
    trimmed = String.trim_leading(text)
    String.starts_with?(trimmed, "<output ") or String.starts_with?(trimmed, "<output\n")
  end

  def output_frame?(_), do: false

  defp compact?(text) do
    byte_size(text) <= @trace_inline_max_bytes and count_lines(text) <= @trace_inline_max_lines
  end

  defp fold_for_trace(text) do
    lines = split_lines(text)
    total = length(lines)
    head_n = min(@trace_head_lines, total)
    tail_n = min(@trace_tail_lines, max(total - head_n, 0))
    omitted = total - head_n - tail_n

    head = lines |> Enum.take(head_n) |> Enum.join("\n")
    tail = lines |> Enum.drop(total - tail_n) |> Enum.join("\n")

    omitted_note =
      if omitted > 0 do
        "\n(… #{omitted} lines omitted — read_tool_transcript for this cycle to see more …)\n"
      else
        "\n"
      end

    head <> omitted_note <> tail
  end

  # --- inline (small) ---

  defp render_inline(kind, attrs, body, size, lines) do
    open = open_tag(kind, attrs, size: size, lines: lines)
    [open, "\n", body, "\n</output>"] |> IO.iodata_to_binary()
  end

  # --- folded (large) ---

  defp render_folded(kind, attrs, blob, body, head_lines, tail_lines) do
    all_lines = split_lines(body)
    total = length(all_lines)

    head_n = min(head_lines, total)
    tail_n = min(tail_lines, max(total - head_n, 0))
    omitted = total - head_n - tail_n

    head_text =
      all_lines
      |> Enum.take(head_n)
      |> Enum.join("\n")

    tail_text =
      all_lines
      |> Enum.drop(total - tail_n)
      |> Enum.join("\n")

    open =
      open_tag(kind, attrs,
        blob: "blob:" <> blob.id,
        size: blob.size,
        lines: total
      )

    omitted_note =
      if omitted > 0 do
        "(#{omitted} lines omitted — use pager id=blob:#{blob.id} mode=read from_line=#{head_n + 1}, or mode=grep pattern=...)"
      else
        ""
      end

    parts =
      [
        open,
        "\n",
        "head (lines 1–#{head_n}):\n",
        head_text,
        if(omitted > 0, do: "\n" <> omitted_note, else: ""),
        if(tail_n > 0,
          do: "\ntail (lines #{total - tail_n + 1}–#{total}):\n" <> tail_text,
          else: ""
        ),
        "\n</output>"
      ]

    IO.iodata_to_binary(parts)
  end

  # --- fallback when blob insert fails ---

  defp render_inline_truncated(kind, attrs, body, size, lines) do
    max = 800

    snippet =
      if byte_size(body) > max, do: binary_part(body, 0, max) <> "\n…(truncated)", else: body

    open = open_tag(kind, attrs, size: size, lines: lines, note: "blob store unavailable")

    [open, "\n", snippet, "\n</output>"] |> IO.iodata_to_binary()
  end

  # --- attr formatting ---

  defp open_tag(kind, user_attrs, extra) do
    all = [{:kind, kind}] ++ extra ++ user_attrs

    rendered =
      all
      |> Enum.flat_map(&format_attr/1)
      |> Enum.join(" ")

    "<output " <> rendered <> ">"
  end

  defp format_attr({_k, nil}), do: []
  defp format_attr({_k, ""}), do: []

  defp format_attr({k, v}) when is_atom(k) do
    [~s(#{k}="#{escape(to_string(v))}")]
  end

  defp format_attr({k, v}) when is_binary(k) do
    [~s(#{k}="#{escape(to_string(v))}")]
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # --- line helpers (local so we don't depend on Blobs internals) ---

  defp split_lines(""), do: []
  defp split_lines(bytes) when is_binary(bytes), do: String.split(bytes, "\n")

  defp count_lines(""), do: 0
  defp count_lines(bytes) when is_binary(bytes), do: length(split_lines(bytes))
end
