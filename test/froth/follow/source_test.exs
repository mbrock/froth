defmodule Froth.Follow.SourceTest do
  use ExUnit.Case, async: false

  alias Froth.Follow.{Filter, Source}
  alias Froth.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Froth.Repo)
  end

  test "recent_entries projects and filters persisted telemetry rows" do
    insert_event(%{
      event: "froth.agent.tool.completed",
      inserted_at: ~U[2026-03-23 16:00:00Z],
      measurements: %{"duration_ms" => 56},
      metadata: %{
        "tool_name" => "read_tool_transcript",
        "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP"
      }
    })

    insert_event(%{
      event: "froth.agent.tool.completed",
      inserted_at: ~U[2026-03-23 16:01:00Z],
      measurements: %{"duration_ms" => 12},
      metadata: %{
        "tool_name" => "other_tool",
        "cycle_id" => "01OTHERCYCLE00000000000000"
      }
    })

    [entry] =
      Source.recent_entries(
        filter: Filter.new(event_prefix: "froth.agent", cycle_id: "01KMDKN3"),
        limit: 10
      )

    assert entry.family == "tool"
    assert entry.scope == "read_tool_transcript"
    assert entry.summary == "completed"
    assert entry.detail =~ "cycle=01KMDKN3"
  end

  defp insert_event(attrs) do
    Repo.insert_all("telemetry_events", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        event: attrs[:event],
        measurements: Map.get(attrs, :measurements, %{}),
        metadata: Map.get(attrs, :metadata, %{}),
        inserted_at: Map.get(attrs, :inserted_at, DateTime.utc_now()),
        span_id: Map.get(attrs, :span_id),
        parent_id: Map.get(attrs, :parent_id)
      }
    ])
  end
end
