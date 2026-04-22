defmodule Froth.Follow.SourceTest do
  use ExUnit.Case, async: true

  alias Froth.Follow.{Filter, Source}
  alias Froth.Repo

  setup tags do
    Repo.put_test_context(tags)
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "recent_entries projects and filters persisted event rows" do
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

    assert entry.event == "froth.agent.tool.completed"
    assert entry.family == "agent"
    assert entry.kind == "tool.completed"
    assert entry.cycle_id == "01KMDKN3GHAC7B814PD3GB4THP"
    assert entry.duration_ms == 56
  end

  defp insert_event(attrs) do
    Repo.insert_all("events", [
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
