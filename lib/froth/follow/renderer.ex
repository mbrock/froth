defmodule Froth.Follow.Renderer do
  @moduledoc false

  alias Froth.Follow.Entry

  @dim "\e[2m"
  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[31m"
  @yellow "\e[33m"
  @green "\e[32m"
  @blue "\e[34m"
  @magenta "\e[35m"
  @cyan "\e[36m"
  @open_symbol "✱"
  @done_symbol "◉"
  @log_symbol "❡"
  @warn_symbol "⚠"
  @error_symbol "✖"

  @spec to_ansi(Entry.t(), Entry.mode()) :: iodata()
  def to_ansi(%Entry{} = entry, mode), do: to_ansi(entry, mode, [])

  @spec to_ansi(Entry.t(), Entry.mode(), keyword()) :: iodata()
  def to_ansi(%Entry{} = entry, :raw, opts) do
    tree_prefix = Keyword.get(opts, :tree_prefix, "")

    [
      raw_primary_line(entry, tree_prefix),
      ?\n,
      raw_secondary_line(entry, tree_prefix)
    ]
  end

  def to_ansi(%Entry{} = entry, mode, opts) when mode in [:smart, :errors] do
    tree_prefix = Keyword.get(opts, :tree_prefix, "")

    [
      smart_primary_line(entry, tree_prefix),
      ?\n,
      smart_secondary_line(entry, tree_prefix)
    ]
  end

  @spec cycle_summary_to_ansi(map()) :: iodata()
  def cycle_summary_to_ansi(%{cycle_id: cycle_id} = summary) do
    [
      cycle_summary_primary_line(summary, cycle_id),
      ?\n,
      cycle_summary_secondary_line(summary)
    ]
  end

  defp raw_primary_line(%Entry{} = entry, tree_prefix) do
    compact([
      tree_prefix_chunks(tree_prefix),
      headline_symbol(entry),
      " ",
      level_color(entry.level),
      single_line(entry.event),
      @reset
    ])
  end

  defp raw_secondary_line(%Entry{} = entry, tree_prefix) do
    compact([
      tree_prefix_chunks(tree_prefix),
      @dim,
      format_time(entry.at),
      @reset,
      " ",
      detail_color(entry.level),
      raw_secondary_text(entry),
      @reset
    ])
  end

  defp smart_primary_line(%Entry{} = entry, tree_prefix) do
    compact([
      tree_prefix_chunks(tree_prefix),
      headline_symbol(entry),
      " ",
      family_color(entry.family, entry.level),
      single_line(entry.family),
      @reset,
      scope_segment(entry.scope),
      scope_segment_separator(entry.scope),
      level_color(entry.level),
      single_line(entry.summary),
      @reset
    ])
  end

  defp smart_secondary_line(%Entry{} = entry, tree_prefix) do
    compact([
      tree_prefix_chunks(tree_prefix),
      @dim,
      format_time(entry.at),
      @reset,
      " ",
      detail_color(entry.level),
      smart_secondary_text(entry),
      @reset
    ])
  end

  defp cycle_summary_primary_line(%{status_level: status_level} = summary, cycle_id) do
    status_level = status_level || :info

    compact([
      cycle_summary_symbol(summary),
      " ",
      family_color("cycle", status_level),
      "cycle",
      @reset,
      " ",
      @dim,
      single_line(cycle_id),
      @reset,
      " ",
      level_color(status_level),
      single_line(summary[:status] || "running"),
      @reset
    ])
  end

  defp cycle_summary_secondary_line(summary) do
    status_level = summary[:status_level] || :info

    compact([
      @dim,
      "  ",
      @reset,
      detail_color(status_level),
      format_cycle_summary(summary),
      @reset
    ])
  end

  defp raw_secondary_text(%Entry{} = entry) do
    [
      entry.duration_ms && [@bold, "#{entry.duration_ms}ms", @reset],
      raw_metadata(entry.metadata)
    ]
    |> compact()
    |> Enum.intersperse(" ")
    |> case do
      [] -> "-"
      secondary -> secondary
    end
  end

  defp smart_secondary_text(%Entry{} = entry) do
    single_line(entry.detail || smart_context(entry) || "-")
  end

  defp smart_context(%Entry{family: "tool", tool_use_id: tool_use_id})
       when is_binary(tool_use_id),
       do: "call=#{short_id(tool_use_id)}"

  defp smart_context(%Entry{family: "control", tool_use_id: tool_use_id})
       when is_binary(tool_use_id),
       do: "call=#{short_id(tool_use_id)}"

  defp smart_context(%Entry{family: "message", message_id: message_id})
       when is_binary(message_id),
       do: "message=#{short_id(message_id)}"

  defp smart_context(%Entry{family: "telegram", message_id: message_id})
       when is_binary(message_id),
       do: "message=#{short_id(message_id)}"

  defp smart_context(_entry), do: nil

  defp raw_metadata(metadata) when map_size(metadata) == 0, do: []

  defp raw_metadata(metadata) do
    metadata
    |> Map.drop(["span_id", "parent_id", "system_time"])
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} ->
      [@dim, key, "=", @reset, format_value(value)]
    end)
    |> Enum.intersperse(" ")
  end

  defp format_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(%NaiveDateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(_), do: "--:--:--.---"

  defp format_cycle_summary(summary) do
    [
      llm_summary(summary[:provider], summary[:model]),
      is_integer(summary[:tool_count]) && "tools=#{summary[:tool_count]}",
      is_integer(summary[:llm_count]) && summary[:llm_count] > 0 && "reqs=#{summary[:llm_count]}",
      is_integer(summary[:elapsed_ms]) && "elapsed=#{format_elapsed(summary[:elapsed_ms])}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "-"
      value -> single_line(value)
    end
  end

  defp format_value(value) when is_binary(value), do: single_line(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"

  defp format_value(value),
    do: single_line(inspect(value, limit: :infinity, printable_limit: :infinity))

  defp level_color(:error), do: @red
  defp level_color(:warn), do: @yellow
  defp level_color(:info), do: @bold
  defp level_color(:debug), do: @dim

  defp detail_color(:error), do: @red
  defp detail_color(:warn), do: @yellow
  defp detail_color(_), do: @dim

  defp family_color(_family, :error), do: @red
  defp family_color(_family, :warn), do: @yellow
  defp family_color("cycle", _), do: @blue
  defp family_color("think", _), do: @cyan
  defp family_color("control", _), do: @blue
  defp family_color("message", _), do: @cyan
  defp family_color("tool", _), do: @green
  defp family_color("llm", _), do: @magenta
  defp family_color("codex", _), do: @magenta
  defp family_color("browser", _), do: @blue
  defp family_color("telegram", _), do: @blue
  defp family_color("task", _), do: @cyan
  defp family_color(_family, _), do: @bold

  defp format_elapsed(value) when value >= 1_000,
    do: :io_lib.format("~.1fs", [value / 1_000]) |> IO.iodata_to_binary()

  defp format_elapsed(value), do: "#{value}ms"

  defp llm_summary(provider, model) when is_binary(provider) and is_binary(model),
    do: "llm=#{provider}:#{model}"

  defp llm_summary(provider, _model) when is_binary(provider), do: "llm=#{provider}"
  defp llm_summary(_provider, _model), do: nil

  defp short_id(nil), do: nil
  defp short_id(value), do: value |> safe_string() |> String.slice(0, 8)

  defp compact(items) do
    Enum.reject(items, &(&1 in [nil, false, []]))
  end

  defp headline_symbol(%Entry{level: :error}), do: @error_symbol
  defp headline_symbol(%Entry{level: :warn}), do: @warn_symbol

  defp headline_symbol(%Entry{} = entry) do
    cond do
      start_like?(entry) -> @open_symbol
      finish_like?(entry) -> @done_symbol
      true -> @log_symbol
    end
  end

  defp cycle_summary_symbol(%{status_level: :error}), do: @error_symbol
  defp cycle_summary_symbol(%{status_level: :warn}), do: @warn_symbol
  defp cycle_summary_symbol(%{active?: true}), do: @open_symbol
  defp cycle_summary_symbol(_summary), do: @done_symbol

  defp start_like?(%Entry{kind: kind, summary: summary}) do
    kind = kind || ""
    summary = single_line(summary || "")

    kind in ["start", "started", "requested", "request_send", "task_started"] or
      summary in [
        "started",
        "thinking started",
        "request started",
        "bot cycle started",
        "session started",
        "task started"
      ] or
      String.ends_with?(summary, " started")
  end

  defp finish_like?(%Entry{kind: kind, summary: summary}) do
    kind = kind || ""
    summary = single_line(summary || "")

    kind in ["stop", "stopped", "completed", "finished", "failed", "cancelled", "timed_out"] or
      summary in [
        "completed",
        "thinking completed",
        "response completed",
        "reply sent",
        "bot cycle completed",
        "stopped without reply",
        "yielded",
        "timed out",
        "browser stopped",
        "captured screenshot",
        "navigated"
      ] or
      String.contains?(summary, "completed") or
      String.contains?(summary, "finished")
  end

  defp tree_prefix_chunks(""), do: []
  defp tree_prefix_chunks(tree_prefix), do: [@dim, tree_indent(tree_prefix), @reset]

  defp tree_indent(tree_prefix) do
    tree_prefix
    |> safe_string()
    |> String.replace(~r/[│├└]/u, " ")
  end

  defp scope_segment(nil), do: []
  defp scope_segment("-"), do: []
  defp scope_segment(scope), do: [" ", @dim, single_line(scope), @reset]

  defp scope_segment_separator(nil), do: []
  defp scope_segment_separator("-"), do: []
  defp scope_segment_separator(_scope), do: " "

  defp safe_string(value) when is_binary(value), do: value

  defp safe_string(value) do
    try do
      to_string(value)
    rescue
      Protocol.UndefinedError ->
        inspect(value, limit: :infinity, printable_limit: :infinity)

      ArgumentError ->
        inspect(value, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp single_line(value) when is_binary(value) do
    value
    |> safe_string()
    |> String.replace(~r/[\r\n\t]+/, " ")
  end

  defp single_line(value), do: value |> safe_string() |> single_line()
end
