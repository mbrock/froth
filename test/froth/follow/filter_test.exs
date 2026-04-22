defmodule Froth.Follow.FilterTest do
  use ExUnit.Case, async: true

  alias Froth.Follow.{Entry, Filter}

  test "matches event prefix and cycle prefix" do
    entry =
      Entry.from_event(%Froth.Event{
        id: Ecto.UUID.generate(),
        event: "froth.agent.tool.completed",
        measurements: %{"duration_ms" => 12},
        metadata: %{
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP",
          "tool_name" => "read_tool_transcript"
        },
        inserted_at: DateTime.utc_now()
      })

    assert Filter.matches?(
             entry,
             Filter.new(event_prefix: "froth.agent", cycle_id: "01KMDKN3")
           )

    refute Filter.matches?(entry, Filter.new(event_prefix: "froth.telegram"))
    refute Filter.matches?(entry, Filter.new(cycle_id: "01OTHER"))
  end

  test "summary renders the filter as key=value pairs" do
    filter = Filter.new(event_prefix: "froth.agent.tool")

    assert Filter.event_segments(filter) == ["froth", "agent", "tool"]
    assert Filter.summary(filter) == ["event=froth.agent.tool"]
  end
end
