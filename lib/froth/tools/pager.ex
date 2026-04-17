defmodule Froth.Tools.Pager do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Blobs
  alias Froth.Context.Block

  @impl true
  def name, do: "pager"

  @impl true
  def label, do: "pager"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Page through or search any blob referenced in your context. Blobs appear as `blob:01K…` inside `<output>` frames (shell output, eval output, analyses, summaries, past transcripts, and so on). Use this to see the middle or full contents of anything you only saw head+tail of, or to find specific passages inside a large output without reading all of it. The grep mode returns line-numbered matches with context and is cheaper than reading the whole blob when you know what you're looking for.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" =>
              "Blob id to read. The `blob:` prefix is optional; both `blob:01K…` and the bare ULID are accepted."
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["read", "head", "tail", "grep", "stat"],
            "description" =>
              "What to do with the blob. `read` (default) returns a line range. `head`/`tail` return the first/last N lines. `grep` searches for a regex and returns matches with line numbers and context. `stat` returns just metadata (size, line count, mime)."
          },
          "from_line" => %{
            "type" => "integer",
            "description" =>
              "For `read`: 1-indexed start line. Defaults to 1. Ignored by the other modes."
          },
          "lines" => %{
            "type" => "integer",
            "description" =>
              "For `read`/`head`/`tail`: number of lines to return. Defaults to 80 for `read`, 40 for `head`/`tail`."
          },
          "pattern" => %{
            "type" => "string",
            "description" =>
              "For `grep`: regex to search for. Matching is case-insensitive by default."
          },
          "before" => %{
            "type" => "integer",
            "description" => "For `grep`: lines of context before each match. Defaults to 0."
          },
          "after" => %{
            "type" => "integer",
            "description" => "For `grep`: lines of context after each match. Defaults to 3."
          },
          "max" => %{
            "type" => "integer",
            "description" => "For `grep`: cap on total matches reported. Defaults to 50."
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" =>
              "For `grep`: set true to make the pattern case-sensitive. Defaults to false."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{}, %ToolUse{input: input}, _hooks) when is_map(input) do
    id = input["id"]
    mode = input["mode"] || "read"

    with {:ok, blob_id} <- Blobs.normalize_id(id) do
      dispatch(blob_id, mode, input)
    else
      {:error, :invalid_id} -> {:error, "invalid blob id"}
    end
  end

  defp dispatch(blob_id, "stat", _input) do
    case Blobs.stat(blob_id) do
      {:ok, stat} ->
        {:ok,
         [
           Block.new(
             [
               kind: "stat",
               blob: blob_id,
               size: stat.size,
               lines: stat.lines,
               mime: stat.mime,
               inserted_at: to_string(stat.inserted_at)
             ],
             nil
           )
         ]}

      {:error, :not_found} ->
        {:error, "blob:#{blob_id} not found"}
    end
  end

  defp dispatch(blob_id, "head", input) do
    lines = bounded_integer(input["lines"], 40, 1, 1000)

    case Blobs.head(blob_id, lines) do
      {:ok, text} ->
        {:ok, [Block.new([kind: "head", blob: blob_id, lines_requested: lines], text)]}

      {:error, :not_found} ->
        {:error, "blob:#{blob_id} not found"}
    end
  end

  defp dispatch(blob_id, "tail", input) do
    lines = bounded_integer(input["lines"], 40, 1, 1000)

    case Blobs.tail(blob_id, lines) do
      {:ok, text} ->
        {:ok, [Block.new([kind: "tail", blob: blob_id, lines_requested: lines], text)]}

      {:error, :not_found} ->
        {:error, "blob:#{blob_id} not found"}
    end
  end

  defp dispatch(blob_id, "read", input) do
    from_line = bounded_integer(input["from_line"], 1, 1, 10_000_000)
    lines = bounded_integer(input["lines"], 80, 1, 1000)

    case Blobs.page(blob_id, from_line: from_line, lines: lines) do
      {:ok, ""} ->
        {:ok, [Block.new([kind: "page", blob: blob_id, from_line: from_line, empty: true], nil)]}

      {:ok, text} ->
        {:ok,
         [
           Block.new(
             [kind: "page", blob: blob_id, from_line: from_line, lines_requested: lines],
             text
           )
         ]}

      {:error, :not_found} ->
        {:error, "blob:#{blob_id} not found"}
    end
  end

  defp dispatch(blob_id, "grep", input) do
    pattern = input["pattern"]

    if not is_binary(pattern) or pattern == "" do
      {:error, "grep requires a non-empty `pattern`"}
    else
      opts = [
        before: bounded_integer(input["before"], 0, 0, 50),
        after: bounded_integer(input["after"], 3, 0, 50),
        max: bounded_integer(input["max"], 50, 1, 500),
        ignore_case: not parse_boolean(input["case_sensitive"], false)
      ]

      case Blobs.grep(blob_id, pattern, opts) do
        {:ok, %{total_matches: 0}} ->
          {:ok, [Block.new([kind: "grep", blob: blob_id, pattern: pattern, total: 0], nil)]}

        {:ok, %{total_matches: total, shown: shown, text: text}} ->
          {:ok,
           [
             Block.new(
               [kind: "grep", blob: blob_id, pattern: pattern, total: total, shown: shown],
               text
             )
           ]}

        {:error, :not_found} ->
          {:error, "blob:#{blob_id} not found"}

        {:error, {:invalid_pattern, reason}} ->
          {:error, "invalid regex pattern: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch(_blob_id, mode, _input) do
    {:error, "unknown pager mode: #{inspect(mode)}"}
  end

  defp bounded_integer(value, default, lower_bound, upper_bound)
       when is_integer(default) and is_integer(lower_bound) and is_integer(upper_bound) do
    parsed = parse_positive_integer(value) || default
    parsed |> max(lower_bound) |> min(upper_bound)
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_positive_integer(_), do: nil

  defp parse_boolean(value, default) when is_boolean(default) do
    cond do
      is_boolean(value) ->
        value

      is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          "true" -> true
          "1" -> true
          "yes" -> true
          "on" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          "off" -> false
          _ -> default
        end

      true ->
        default
    end
  end
end
