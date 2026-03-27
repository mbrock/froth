defmodule Froth.Agent.ToolDescription do
  @moduledoc false

  def text_from_input(input) when is_map(input) do
    case normalize_input(input) do
      nil -> nil
      description -> render_text(description)
    end
  end

  def text_from_input(_input), do: nil

  defp normalize_input(input) when is_map(input) do
    case description_value(input) do
      %{} = description ->
        normalize_description(description)

      _ ->
        normalize_legacy_narration(narration_value(input))
    end
  end

  defp normalize_description(description) when is_map(description) do
    action = normalize_text(action_value(description))
    goals = normalize_list(goals_value(description), 3)
    assumptions = normalize_list(assumptions_value(description))

    if action || goals != [] || assumptions != [] do
      %{action: action, goals: goals, assumptions: assumptions}
    else
      nil
    end
  end

  defp normalize_description(_description), do: nil

  defp normalize_legacy_narration(narration) when is_binary(narration) do
    case normalize_text(narration) do
      nil -> nil
      action -> %{action: action, goals: [], assumptions: []}
    end
  end

  defp normalize_legacy_narration(_narration), do: nil

  defp render_text(%{action: action, goals: goals, assumptions: assumptions}) do
    []
    |> maybe_append_line(action)
    |> maybe_append_line(join_labeled_list("Goal stack", goals, " -> "))
    |> maybe_append_line(join_labeled_list("Assumptions", assumptions, "; "))
    |> Enum.join("\n")
  end

  defp maybe_append_line(lines, nil), do: lines
  defp maybe_append_line(lines, ""), do: lines
  defp maybe_append_line(lines, line), do: lines ++ [line]

  defp join_labeled_list(_label, [], _separator), do: nil

  defp join_labeled_list(label, items, separator) when is_list(items) and is_binary(separator) do
    label <> ": " <> Enum.join(items, separator)
  end

  defp normalize_list(items, limit \\ nil)

  defp normalize_list(items, limit) when is_list(items) do
    items
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> maybe_take(limit)
  end

  defp normalize_list(item, limit) when is_binary(item) do
    [item]
    |> normalize_list(limit)
  end

  defp normalize_list(_items, _limit), do: []

  defp maybe_take(items, limit) when is_integer(limit) and limit > 0, do: Enum.take(items, limit)
  defp maybe_take(items, _limit), do: items

  defp normalize_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_text), do: nil

  defp description_value(map), do: Map.get(map, "description") || Map.get(map, :description)
  defp narration_value(map), do: Map.get(map, "narration") || Map.get(map, :narration)
  defp action_value(map), do: Map.get(map, "action") || Map.get(map, :action)
  defp goals_value(map), do: Map.get(map, "goals") || Map.get(map, :goals)
  defp assumptions_value(map), do: Map.get(map, "assumptions") || Map.get(map, :assumptions)
end
