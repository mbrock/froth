defmodule Froth.Follow.FilterTest do
  use ExUnit.Case, async: true

  alias Froth.Follow.{Filter, Projector}

  test "matches event prefix and cycle prefix against projected entries" do
    entry =
      Projector.from_live(
        [:froth, :agent, :tool, :completed],
        %{duration_ms: 12},
        %{
          cycle_id: "01KMDKN3GHAC7B814PD3GB4THP",
          tool_name: "read_tool_transcript"
        }
      )

    assert Filter.matches?(entry, Filter.new(event_prefix: "froth.agent", cycle_id: "01KMDKN3"))
    refute Filter.matches?(entry, Filter.new(event_prefix: "froth.telegram"))
    refute Filter.matches?(entry, Filter.new(cycle_id: "01OTHER"))
  end

  test "splits event prefixes for telemetry subscription filtering" do
    filter = Filter.new(event_prefix: "froth.agent.tool")

    assert Filter.event_segments(filter) == ["froth", "agent", "tool"]
    assert Filter.summary(filter) == ["event=froth.agent.tool"]
  end
end
