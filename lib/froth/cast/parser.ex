defmodule Froth.Cast.Parser do
  @moduledoc false

  alias Froth.Cast.Recording
  alias Froth.Cast.Theme

  def parse_file(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, contents} <- File.read(path) do
      parse(contents)
    else
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  def parse(contents) when is_binary(contents) do
    contents = strip_bom(contents)
    lines = String.split(contents, ~r/\r\n|\n|\r/, trim: false)

    with {:ok, recording} <- parse_from_lines(lines, contents) do
      {:ok, attach_max_dimensions(recording)}
    end
  end

  defp parse_from_lines(lines, contents) do
    case first_nonempty_line(lines) do
      nil ->
        {:error, :empty_cast}

      first_line ->
        case Jason.decode(first_line) do
          {:ok, %{"version" => version} = header} when version in [2, 3] ->
            parse_ndjson(lines, header, version)

          _ ->
            parse_v1(contents)
        end
    end
  end

  defp parse_v1(contents) do
    with {:ok, %{"version" => 1} = payload} <- Jason.decode(contents),
         {:ok, cols} <- positive_integer(payload["width"]),
         {:ok, rows} <- positive_integer(payload["height"]) do
      events =
        payload["stdout"]
        |> List.wrap()
        |> Enum.reduce({[], 0.0}, fn
          [delay, data], {acc, at} ->
            event_at = at + float_value(delay)
            event = %{at: event_at, code: "o", data: to_string(data || "")}
            {[event | acc], event_at}

          _other, acc ->
            acc
        end)
        |> elem(0)
        |> Enum.reverse()

      recording =
        %Recording{
          version: 1,
          cols: cols,
          rows: rows,
          terminal_type: (payload["env"] || %{}) |> Map.get("TERM"),
          timestamp: payload["timestamp"],
          duration_s: payload["duration"] |> float_value(last_event_time(events)),
          idle_time_limit: nil,
          command: payload["command"],
          title: payload["title"],
          env: payload["env"] || %{},
          theme: normalize_theme(nil),
          events: events
        }

      {:ok, recording}
    else
      {:ok, %{"version" => version}} -> {:error, {:unsupported_version, version}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_cast, error.data}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_ndjson(lines, header, version) do
    with {:ok, {cols, rows, terminal_type, terminal_version, theme}} <-
           parse_header_terminal(header, version) do
      header_line = first_nonempty_line(lines)

      event_lines =
        lines
        |> drop_until(header_line)
        |> tl_or_empty()

      events =
        event_lines
        |> Enum.reduce({[], 0.0}, fn line, {acc, clock} ->
          trimmed = String.trim(line)

          cond do
            trimmed == "" or String.starts_with?(trimmed, "#") ->
              {acc, clock}

            true ->
              case Jason.decode(trimmed) do
                {:ok, [time_or_interval, code, data]} ->
                  current_time =
                    case version do
                      2 -> float_value(time_or_interval)
                      3 -> clock + float_value(time_or_interval)
                    end

                  event = %{at: current_time, code: to_string(code), data: data}
                  {[event | acc], current_time}

                _ ->
                  {acc, clock}
              end
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      recording =
        %Recording{
          version: version,
          cols: cols,
          rows: rows,
          terminal_type: terminal_type,
          terminal_version: terminal_version,
          timestamp: header["timestamp"],
          duration_s: header["duration"] |> float_value(last_event_time(events)),
          idle_time_limit: nullable_float(header["idle_time_limit"]),
          command: header["command"],
          title: header["title"],
          env: header["env"] || %{},
          theme: normalize_theme(theme),
          events: events
        }

      {:ok, recording}
    end
  end

  defp parse_header_terminal(header, 2) do
    with {:ok, cols} <- positive_integer(header["width"]),
         {:ok, rows} <- positive_integer(header["height"]) do
      terminal_type =
        header
        |> Map.get("env", %{})
        |> Map.get("TERM")

      {:ok, {cols, rows, terminal_type, nil, header["theme"]}}
    end
  end

  defp parse_header_terminal(header, 3) do
    term = header["term"] || %{}

    with {:ok, cols} <- positive_integer(term["cols"]),
         {:ok, rows} <- positive_integer(term["rows"]) do
      terminal_type = term["type"] || header |> Map.get("env", %{}) |> Map.get("TERM")
      {:ok, {cols, rows, terminal_type, term["version"], term["theme"]}}
    end
  end

  defp attach_max_dimensions(%Recording{} = recording) do
    {_cols, _rows, max_cols, max_rows} =
      Enum.reduce(
        recording.events,
        {recording.cols, recording.rows, recording.cols, recording.rows},
        fn
          %{code: "r", data: data}, {cols, rows, max_cols, max_rows} ->
            case parse_resize(data) do
              {:ok, {new_cols, new_rows}} ->
                {new_cols, new_rows, max(max_cols, new_cols), max(max_rows, new_rows)}

              :error ->
                {cols, rows, max_cols, max_rows}
            end

          _, acc ->
            acc
        end
      )

    %{recording | max_cols: max_cols, max_rows: max_rows}
  end

  defp normalize_theme(theme) do
    case Theme.normalize(theme) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp parse_resize(data) when is_binary(data) do
    case String.split(data, "x", parts: 2) do
      [cols, rows] ->
        with {cols, ""} <- Integer.parse(cols),
             {rows, ""} <- Integer.parse(rows),
             true <- cols > 0 and rows > 0 do
          {:ok, {cols, rows}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_resize(_data), do: :error

  defp first_nonempty_line(lines) do
    Enum.find(lines, fn line -> String.trim(line) != "" end)
  end

  defp drop_until(lines, target_line) do
    {_dropped, remaining} = Enum.split_while(lines, &(&1 != target_line))
    remaining
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_head | tail]), do: tail

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_terminal_size}

  defp nullable_float(nil), do: nil
  defp nullable_float(value), do: float_value(value)

  defp float_value(value, fallback \\ 0.0)

  defp float_value(nil, fallback), do: fallback
  defp float_value(value, _fallback) when is_float(value), do: value
  defp float_value(value, _fallback) when is_integer(value), do: value * 1.0

  defp float_value(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> fallback
    end
  end

  defp float_value(_value, fallback), do: fallback

  defp last_event_time([]), do: 0.0
  defp last_event_time(events), do: events |> List.last() |> Map.fetch!(:at)

  defp strip_bom(contents) do
    case contents do
      <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
      _ -> contents
    end
  end
end
