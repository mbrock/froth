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
  @family_width 7
  @scope_width 12
  @tree_width 8

  @spec to_ansi(Entry.t(), Entry.mode()) :: iodata()
  def to_ansi(%Entry{} = entry, mode), do: to_ansi(entry, mode, [])

  @spec to_ansi(Entry.t(), Entry.mode(), keyword()) :: iodata()
  def to_ansi(%Entry{} = entry, :raw, _opts) do
    raw_name = entry.event
    duration = entry.duration_ms && "#{entry.duration_ms}ms"
    metadata = raw_metadata(entry.metadata)

    compact([
      @dim,
      format_time(entry.at),
      @reset,
      " ",
      level_color(entry.level),
      raw_name,
      @reset,
      duration && [" ", @bold, duration, @reset],
      metadata != [] && [" ", metadata]
    ])
  end

  def to_ansi(%Entry{} = entry, mode, opts) when mode in [:smart, :errors] do
    tree_prefix = Keyword.get(opts, :tree_prefix, "")

    compact([
      @dim,
      format_time(entry.at),
      @reset,
      " ",
      family_color(entry.family, entry.level),
      fit(entry.family, @family_width),
      @reset,
      " ",
      @dim,
      fit(entry.scope || "-", @scope_width),
      @reset,
      " ",
      @dim,
      fit(tree_prefix, @tree_width),
      @reset,
      " ",
      level_color(entry.level),
      entry.summary,
      @reset,
      entry.detail && ["  ", @dim, truncate_text(entry.detail, 64), @reset]
    ])
  end

  @spec cycle_summary_to_ansi(map()) :: iodata()
  def cycle_summary_to_ansi(%{cycle_id: cycle_id} = summary) do
    compact([
      @dim,
      fit("", 12),
      @reset,
      " ",
      family_color("cycle", summary[:status_level] || :info),
      fit("cycle", @family_width),
      @reset,
      " ",
      @dim,
      fit(short_id(cycle_id) || "-", @scope_width),
      @reset,
      " ",
      @dim,
      fit("└", @tree_width),
      @reset,
      " ",
      level_color(summary[:status_level] || :info),
      "summary",
      @reset,
      "  ",
      @dim,
      format_cycle_summary(summary),
      @reset
    ])
  end

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
      is_integer(summary[:elapsed_ms]) && "elapsed=#{format_elapsed(summary[:elapsed_ms])}",
      is_binary(summary[:status]) && "status=#{summary[:status]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_value(value) when is_binary(value) and byte_size(value) > 80,
    do: String.slice(value, 0, 80) <> "..."

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(value), do: inspect(value, limit: 5, printable_limit: 80)

  defp level_color(:error), do: @red
  defp level_color(:warn), do: @yellow
  defp level_color(:info), do: @bold
  defp level_color(:debug), do: @dim

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

  defp fit(value, width) do
    value
    |> safe_string()
    |> truncate_text(width)
    |> String.pad_trailing(width)
  end

  defp truncate_text(value, width)
       when is_binary(value) and width > 3 and byte_size(value) > width,
       do: String.slice(value, 0, width - 3) <> "..."

  defp truncate_text(value, _width), do: value

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
    Enum.reject(items, &(&1 in [nil, false]))
  end

  defp safe_string(value) when is_binary(value), do: value

  defp safe_string(value) do
    try do
      to_string(value)
    rescue
      Protocol.UndefinedError -> inspect(value, limit: 8, printable_limit: 160)
      ArgumentError -> inspect(value, limit: 8, printable_limit: 160)
    end
  end
end
