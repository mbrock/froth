defmodule Froth.Comic.Layout do
  @moduledoc """
  Deterministic panel, character, and balloon layout for `Froth.Comic`.

  Comic Chat's original constraints are preserved in spirit: a repeated
  speaker starts a new panel, panels hold at most a small cast, characters sit
  in the lower field, and balloons reserve routes to their speakers.
  """

  alias Froth.Comic.Semantic

  @default_width 1200
  @default_columns 2
  @gap 16
  @padding 20
  @avatar_names ~w(waf glenda pedagog rainbow tux)

  @spec layout([map()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def layout(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    with {:ok, messages} <- normalize_messages(messages) do
      width = Keyword.get(opts, :width, @default_width)
      columns = Keyword.get(opts, :columns, @default_columns)

      cond do
        messages == [] ->
          {:error, "comic requires at least one message"}

        not is_integer(width) or width < 480 ->
          {:error, "comic width must be an integer of at least 480 pixels"}

        columns not in 1..3 ->
          {:error, "comic columns must be between 1 and 3"}

        true ->
          {:ok, build(messages, width, columns)}
      end
    end
  end

  defp normalize_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      sender = fetch(message, :sender)
      text = fetch(message, :text)

      if is_map(message) and present?(sender) and is_binary(text) and
           String.trim(text) != "" do
        normalized = %{
          id: index,
          sender: to_string(sender),
          text: text,
          timestamp: fetch(message, :timestamp),
          semantics: Semantic.analyze(message)
        }

        {:cont, {:ok, [normalized | acc]}}
      else
        {:halt,
         {:error, "message #{index} must have a sender and non-empty text"}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp build(messages, width, columns) do
    panel_groups = group_panels(messages)
    unit_width = div(width - @padding * 2 - @gap * (columns - 1), columns)

    specs =
      Enum.map(panel_groups, fn group ->
        span = panel_span(group, columns)
        panel_width = unit_width * span + @gap * (span - 1)
        prepared = prepare_balloons(group, panel_width)

        height =
          max(420, 190 + Enum.sum(Enum.map(prepared, & &1.height)) + 36)

        %{
          messages: prepared,
          span: span,
          width: panel_width,
          height: min(height, 680)
        }
      end)

    {panels, bottom} = place_rows(specs, columns, unit_width)

    %{
      width: width,
      height: bottom + @padding,
      columns: columns,
      gap: @gap,
      panels: Enum.with_index(panels, &decorate_panel(&1, &2))
    }
  end

  defp group_panels(messages) do
    {groups, current} =
      Enum.reduce(messages, {[], []}, fn message, {groups, current} ->
        if new_panel?(current, message) do
          {[Enum.reverse(current) | groups], [message]}
        else
          {groups, [message | current]}
        end
      end)

    Enum.reverse([Enum.reverse(current) | groups])
  end

  defp new_panel?([], _message), do: false

  defp new_panel?(current, message) do
    current = Enum.reverse(current)
    senders = MapSet.new(current, & &1.sender)
    balloon_lines = Enum.sum(Enum.map(current, &estimated_lines(&1.text, 34)))

    length(current) >= 4 or
      MapSet.member?(senders, message.sender) or
      message.semantics.balloon == :action or
      List.last(current).semantics.balloon == :action or
      balloon_lines + estimated_lines(message.text, 34) > 13 or
      distant_timestamps?(List.last(current).timestamp, message.timestamp)
  end

  defp panel_span([message], columns) when columns > 1 do
    if message.semantics.balloon == :shout or
         String.length(message.text) > 150,
       do: columns,
       else: 1
  end

  defp panel_span(_messages, _columns), do: 1

  defp prepare_balloons(messages, panel_width) do
    max_chars = max(18, trunc(panel_width * 0.66 / 11))

    Enum.map(messages, fn message ->
      lines = wrap(message.text, max_chars)

      Map.merge(message, %{
        lines: lines,
        height: max(82, 58 + length(lines) * 24)
      })
    end)
  end

  defp place_rows(specs, columns, unit_width) do
    rows = pack_rows(specs, columns)

    Enum.reduce(rows, {[], @padding}, fn row, {panels, y} ->
      row_height = row |> Enum.map(& &1.height) |> Enum.max()

      {placed, _used} =
        Enum.map_reduce(row, 0, fn spec, used ->
          x = @padding + used * (unit_width + @gap)

          {Map.merge(spec, %{x: x, y: y, height: row_height}),
           used + spec.span}
        end)

      {panels ++ placed, y + row_height + @gap}
    end)
    |> then(fn {panels, y} -> {panels, y - @gap} end)
  end

  defp pack_rows(specs, columns) do
    {rows, row, _used} =
      Enum.reduce(specs, {[], [], 0}, fn spec, {rows, row, used} ->
        if used + spec.span > columns do
          {[Enum.reverse(row) | rows], [spec], spec.span}
        else
          {rows, [spec | row], used + spec.span}
        end
      end)

    Enum.reverse([Enum.reverse(row) | rows])
  end

  defp decorate_panel(panel, index) do
    senders = panel.messages |> Enum.map(& &1.sender) |> Enum.uniq()
    character_top = panel.y + panel.height - 205

    characters =
      senders
      |> Enum.with_index()
      |> Enum.map(fn {sender, slot} ->
        center_x =
          panel.x + div(panel.width * (slot * 2 + 1), length(senders) * 2)

        semantics =
          panel.messages
          |> Enum.filter(&(&1.sender == sender))
          |> List.last()
          |> Map.fetch!(:semantics)

        %{
          sender: sender,
          avatar: avatar_for(sender),
          semantics: semantics,
          center_x: center_x,
          x: center_x - 78,
          y: character_top,
          width: 156,
          height: 196
        }
      end)

    character_by_sender = Map.new(characters, &{&1.sender, &1})

    {balloons, _y} =
      Enum.map_reduce(panel.messages, panel.y + 24, fn message, y ->
        character = Map.fetch!(character_by_sender, message.sender)

        bubble_width =
          min(
            trunc(panel.width * 0.72),
            max(220, widest_line(message.lines) * 11 + 42)
          )

        min_x = panel.x + 18
        max_x = panel.x + panel.width - bubble_width - 18
        x = clamp(character.center_x - div(bubble_width, 2), min_x, max_x)

        balloon =
          Map.merge(message, %{
            x: x,
            y: y,
            width: bubble_width,
            speaker_x: character.center_x,
            speaker_y: character.y + 42
          })

        {balloon, y + message.height}
      end)

    panel
    |> Map.put(:id, index)
    |> Map.put(:backdrop, Enum.at(~w(field pastoral room8bs), rem(index, 3)))
    |> Map.put(:characters, characters)
    |> Map.put(:balloons, balloons)
    |> Map.delete(:messages)
  end

  @doc false
  def wrap(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] ->
        if String.length(line) + String.length(word) + 1 <= max_chars,
          do: [line <> " " <> word | rest],
          else: [word, line | rest]
    end)
    |> Enum.reverse()
    |> case do
      [] -> [""]
      lines -> lines
    end
  end

  defp estimated_lines(text, max_chars), do: length(wrap(text, max_chars))

  defp widest_line(lines),
    do: lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 1 end)

  defp avatar_for(sender),
    do:
      Enum.at(
        @avatar_names,
        rem(:erlang.phash2(sender), length(@avatar_names))
      )

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp distant_timestamps?(first, second) do
    with {:ok, first} <- datetime(first),
         {:ok, second} <- datetime(second) do
      abs(DateTime.diff(second, first, :second)) > 300
    else
      _ -> false
    end
  end

  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(%NaiveDateTime{} = value),
    do: DateTime.from_naive(value, "Etc/UTC")

  defp datetime(value) when is_integer(value), do: DateTime.from_unix(value)
  defp datetime(_value), do: :error

  defp fetch(map, key),
    do:
      if(is_map(map),
        do: Map.get(map, key, Map.get(map, Atom.to_string(key))),
        else: nil
      )

  defp present?(value),
    do: not is_nil(value) and String.trim(to_string(value)) != ""
end
