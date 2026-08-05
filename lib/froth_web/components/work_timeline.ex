defmodule FrothWeb.WorkTimeline do
  @moduledoc """
  Shared presentation boundary for agent work timelines.

  The full chat timeline, focused Telegram mini-app, and Codex mini-app keep
  their own data loading and controls, but render tool work through this
  component so the visual language and tool-specific formatting stay aligned.
  """
  use FrothWeb, :html

  alias FrothWeb.TimelineLive

  attr :cycle, :map, required: true

  def cycle_trace(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <%= for entry <- @cycle.entries do %>
        <.tool_entry entry={entry} />
      <% end %>
    </div>
    """
  end

  attr :entry, :map, required: true

  def tool_entry(assigns), do: TimelineLive.tool_entry(assigns)

  @doc "Pairs persisted tool calls with their outcomes for display."
  def summarize_cycle(entries) do
    {rows, pending} =
      Enum.reduce(entries, {[], nil}, fn entry, {acc, pending} ->
        case entry.kind do
          :call ->
            acc = if pending, do: [pending | acc], else: acc
            {acc, entry}

          :return ->
            row =
              Map.put(
                pending || %{kind: :call, tool: "?"},
                :result,
                entry.outcome
              )

            {[row | acc], nil}

          :intervention ->
            row =
              Map.put(
                pending || %{kind: :call, tool: "?"},
                :result,
                {:intervention, entry[:text] || entry[:data]}
              )

            {[row | acc], nil}

          _ ->
            {acc, pending}
        end
      end)

    rows = if pending, do: [pending | rows], else: rows
    Enum.reverse(rows)
  end
end
