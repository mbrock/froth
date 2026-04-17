defmodule Froth.Blobs do
  @moduledoc """
  Content store for "big things the agent should not inline."

  `put/2` freezes a binary under a fresh ULID and returns `{:ok, %Blob{}}`.
  Readers use `stat/1`, `head/2`, `tail/2`, `page/3`, and `grep/3` to
  pull views of a blob without hauling the whole thing into context.

  IDs are rendered as 26-char Crockford-base32 ULIDs (what `Ecto.ULID`
  produces natively) and shown to the model as `blob:<id>`. `normalize_id/1`
  accepts either form, tolerating the `blob:` prefix.

  Grep results that are themselves large are stored as a new blob and
  returned by id — the pager is recursively composable.
  """

  alias Froth.{Blob, Repo}
  import Ecto.Query

  @prefix "blob:"

  @doc """
  Insert a new blob.

  Attrs: `:mime` (default `"text/plain"`), `:lines` (computed from the
  body if omitted and the mime looks textual). Size is always computed
  from the body.
  """
  @spec put(binary(), keyword()) :: {:ok, Blob.t()} | {:error, term()}
  def put(body, attrs \\ []) when is_binary(body) and is_list(attrs) do
    mime = Keyword.get(attrs, :mime, "text/plain")
    size = byte_size(body)

    lines =
      case Keyword.get(attrs, :lines) do
        n when is_integer(n) and n >= 0 -> n
        _ -> if textual_mime?(mime), do: count_lines(body), else: nil
      end

    blob = %Blob{bytes: body, mime: mime, size: size, lines: lines}

    case Repo.insert(blob, log: false) do
      {:ok, inserted} -> {:ok, inserted}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Fetch a blob by id, including bytes.
  """
  @spec get(String.t()) :: {:ok, Blob.t()} | {:error, :not_found | :invalid_id}
  def get(id) do
    with {:ok, id} <- normalize_id(id),
         %Blob{} = blob <- Repo.get(Blob, id, log: false) do
      {:ok, blob}
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Summary info about a blob, without loading bytes.
  """
  @spec stat(String.t()) :: {:ok, map()} | {:error, :not_found | :invalid_id}
  def stat(id) do
    with {:ok, id} <- normalize_id(id) do
      case Repo.one(
             from(b in Blob,
               where: b.id == ^id,
               select: %{
                 id: b.id,
                 mime: b.mime,
                 size: b.size,
                 lines: b.lines,
                 inserted_at: b.inserted_at
               }
             ),
             log: false
           ) do
        nil -> {:error, :not_found}
        stat -> {:ok, stat}
      end
    end
  end

  @doc """
  Render a blob id with the `blob:` prefix.
  """
  @spec render_id(String.t()) :: String.t()
  def render_id(id) when is_binary(id), do: @prefix <> id

  @doc """
  Accept either `"blob:01K…"` or the bare 26-char ULID, return the bare
  canonical ULID. Rejects anything else.
  """
  @spec normalize_id(String.t() | any()) :: {:ok, String.t()} | {:error, :invalid_id}
  def normalize_id(id) when is_binary(id) do
    trimmed = String.trim(id)

    stripped =
      case trimmed do
        @prefix <> rest -> rest
        _ -> trimmed
      end
      |> String.upcase()

    case Ecto.ULID.cast(stripped) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_id}
    end
  end

  def normalize_id(_), do: {:error, :invalid_id}

  @doc """
  Return the first `lines` lines of a textual blob as a single string.
  Does not include a trailing newline unless the source did.
  """
  @spec head(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, :not_found | :invalid_id}
  def head(id, lines \\ 10) when is_integer(lines) and lines >= 0 do
    with {:ok, %Blob{bytes: bytes}} <- get(id) do
      {:ok, take_head(bytes, lines)}
    end
  end

  @doc """
  Return the last `lines` lines of a textual blob.
  """
  @spec tail(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, :not_found | :invalid_id}
  def tail(id, lines \\ 10) when is_integer(lines) and lines >= 0 do
    with {:ok, %Blob{bytes: bytes}} <- get(id) do
      {:ok, take_tail(bytes, lines)}
    end
  end

  @doc """
  Return a range of lines from a textual blob (1-indexed inclusive).

  `from_line` defaults to 1 and `lines` to 80. If `from_line` exceeds
  the blob length an empty string is returned.
  """
  @spec page(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def page(id, opts \\ []) do
    from_line = Keyword.get(opts, :from_line, 1)
    lines = Keyword.get(opts, :lines, 80)

    with {:ok, %Blob{bytes: bytes}} <- get(id) do
      {:ok, take_range(bytes, from_line, lines)}
    end
  end

  @doc """
  ripgrep-ish search inside a single blob.

  Options:
    * `:before` — context lines before each match (default 0)
    * `:after`  — context lines after each match (default 3)
    * `:max`    — cap total matches (default 50)
    * `:ignore_case` — default true

  Returns `{:ok, %{total_matches, shown, text}}` where `text` is a
  ready-to-paginate rendering. Raises on invalid regex.
  """
  @spec grep(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def grep(id, pattern, opts \\ []) when is_binary(pattern) do
    before_n = Keyword.get(opts, :before, 0)
    after_n = Keyword.get(opts, :after, 3)
    max_n = Keyword.get(opts, :max, 50)
    ignore_case = Keyword.get(opts, :ignore_case, true)

    with {:ok, regex} <- compile_pattern(pattern, ignore_case),
         {:ok, %Blob{bytes: bytes}} <- get(id) do
      lines = split_lines(bytes)

      matches =
        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _i} -> Regex.match?(regex, line) end)

      total = length(matches)
      shown = Enum.take(matches, max_n)
      text = render_grep(lines, shown, before_n, after_n)

      {:ok, %{total_matches: total, shown: length(shown), text: text}}
    end
  end

  # --- line helpers ---

  defp take_head(bytes, n) when is_binary(bytes) do
    bytes
    |> split_lines()
    |> Enum.take(n)
    |> Enum.join("\n")
  end

  defp take_tail(bytes, n) when is_binary(bytes) do
    lines = split_lines(bytes)
    total = length(lines)
    start = max(total - n, 0)

    lines
    |> Enum.drop(start)
    |> Enum.join("\n")
  end

  defp take_range(bytes, from_line, count) when is_binary(bytes) do
    lines = split_lines(bytes)
    start = max(from_line - 1, 0)

    lines
    |> Enum.drop(start)
    |> Enum.take(count)
    |> Enum.join("\n")
  end

  defp render_grep(_lines, [], _before, _after), do: "(no matches)"

  defp render_grep(lines, shown, before_n, after_n) do
    line_count = length(lines)
    hit_set = MapSet.new(shown, fn {_line, i} -> i end)

    expanded =
      shown
      |> Enum.flat_map(fn {_line, i} ->
        lo = max(i - before_n, 1)
        hi = min(i + after_n, line_count)
        Enum.to_list(lo..hi)
      end)
      |> Enum.sort()
      |> Enum.uniq()

    expanded
    |> chunk_consecutive()
    |> Enum.map_join("\n--\n", fn chunk ->
      Enum.map_join(chunk, "\n", fn i ->
        marker = if MapSet.member?(hit_set, i), do: ":", else: "-"
        line = Enum.at(lines, i - 1, "")
        "#{pad_line_no(i)}#{marker} #{line}"
      end)
    end)
  end

  defp chunk_consecutive(ints), do: chunk_consecutive(ints, [], [])

  defp chunk_consecutive([], acc_group, acc) do
    acc = if acc_group == [], do: acc, else: [Enum.reverse(acc_group) | acc]
    Enum.reverse(acc)
  end

  defp chunk_consecutive([x | rest], [], acc), do: chunk_consecutive(rest, [x], acc)

  defp chunk_consecutive([x | rest], [prev | _] = group, acc) when x == prev + 1,
    do: chunk_consecutive(rest, [x | group], acc)

  defp chunk_consecutive([x | rest], group, acc),
    do: chunk_consecutive(rest, [x], [Enum.reverse(group) | acc])

  defp pad_line_no(i), do: String.pad_leading(Integer.to_string(i), 6, " ")

  defp compile_pattern(pattern, ignore_case) do
    opts = if ignore_case, do: [:unicode, :caseless], else: [:unicode]

    case Regex.compile(pattern, opts) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _pos}} -> {:error, {:invalid_pattern, reason}}
    end
  end

  defp split_lines(bytes) when is_binary(bytes) do
    # Keep trailing-newline-but-no-content out of the count (common for
    # shell output). Split on \n but drop a single empty trailing chunk.
    case String.split(bytes, "\n") do
      [head | rest] ->
        case Enum.reverse(rest) do
          ["" | middle] -> [head | Enum.reverse(middle)]
          _ -> [head | rest]
        end

      [] ->
        []
    end
  end

  defp count_lines(""), do: 0
  defp count_lines(bytes) when is_binary(bytes), do: length(split_lines(bytes))

  defp textual_mime?(mime) when is_binary(mime) do
    String.starts_with?(mime, "text/") or
      mime in ["application/json", "application/xml", "application/yaml"]
  end

  defp textual_mime?(_), do: false
end
