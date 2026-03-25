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

  @spec to_ansi(Entry.t(), Entry.mode()) :: iodata()
  def to_ansi(%Entry{} = entry, :raw) do
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

  def to_ansi(%Entry{} = entry, mode) when mode in [:smart, :errors] do
    compact([
      @dim,
      format_time(entry.at),
      @reset,
      " ",
      family_color(entry.family, entry.level),
      String.pad_trailing(entry.family, 9),
      @reset,
      " ",
      @dim,
      String.pad_trailing(entry.scope || "-", 12),
      @reset,
      " ",
      level_color(entry.level),
      entry.summary,
      @reset,
      entry.detail && ["  ", @dim, entry.detail, @reset]
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
  defp family_color("telegram", _), do: @blue
  defp family_color("task", _), do: @cyan
  defp family_color(_family, _), do: @bold

  defp compact(items) do
    Enum.reject(items, &(&1 in [nil, false]))
  end
end
