defmodule FrothWeb.TelemetryLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Froth.Repo

  test "smart mode renders projected semantic entries", %{conn: conn} do
    id =
      insert_event(%{
        event: "froth.agent.tool.completed",
        measurements: %{"duration_ms" => 56},
        metadata: %{
          "tool_name" => "read_tool_transcript",
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP",
          "result_type" => "text"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/froth/telemetry")

    assert has_element?(view, "#telemetry-table")
    assert has_element?(view, "#telemetry-mode-smart")
    assert has_element?(view, "#event-#{id}", "tool")
    assert has_element?(view, "#event-#{id}", "read_tool_transcript")
    assert has_element?(view, "#event-#{id}", "completed")

    view
    |> element("#event-#{id}")
    |> render_click()

    assert has_element?(view, "#event-detail-#{id}")
    assert has_element?(view, "#event-json-#{id}", "\"tool_name\": \"read_tool_transcript\"")
  end

  test "raw mode reveals events hidden in smart mode", %{conn: conn} do
    id =
      insert_event(%{
        event: "froth.llm.edit",
        metadata: %{
          "provider" => "anthropic",
          "op" => "append",
          "resource_id" => "message/blocks/0"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/froth/telemetry")

    refute has_element?(view, "#event-#{id}")

    view
    |> element("#telemetry-mode-raw")
    |> render_click()

    assert has_element?(view, "#event-#{id}", "llm.edit")
    assert has_element?(view, "#event-#{id}", "anthropic")
  end

  test "entry scope buttons narrow the timeline to one cycle", %{conn: conn} do
    matching_id =
      insert_event(%{
        event: "froth.agent.tool.completed",
        metadata: %{
          "tool_name" => "read_tool_transcript",
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP"
        }
      })

    other_id =
      insert_event(%{
        event: "froth.agent.tool.completed",
        metadata: %{
          "tool_name" => "other_tool",
          "cycle_id" => "01OTHERCYCLE00000000000000"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/froth/telemetry")

    view
    |> element("#event-#{matching_id}")
    |> render_click()

    view
    |> element("#event-filter-cycle-#{matching_id}")
    |> render_click()

    assert_patch(view, ~p"/froth/telemetry?cycle=01KMDKN3GHAC7B814PD3GB4THP")
    assert has_element?(view, "#telemetry-scope-filters", "cycle 01KMDKN3GHAC7B814PD3GB4THP")
    assert has_element?(view, "#event-#{matching_id}")
    refute has_element?(view, "#event-#{other_id}")
  end

  test "query params restore a scoped raw view", %{conn: conn} do
    matching_id =
      insert_event(%{
        event: "froth.llm.edit",
        metadata: %{
          "provider" => "anthropic",
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP"
        }
      })

    other_id =
      insert_event(%{
        event: "froth.llm.edit",
        metadata: %{
          "provider" => "openai",
          "cycle_id" => "01OTHERCYCLE00000000000000"
        }
      })

    {:ok, view, _html} =
      live(conn, ~p"/froth/telemetry?cycle=01KMDKN3GHAC7B814PD3GB4THP&mode=raw")

    assert has_element?(view, "#telemetry-scope-filters", "cycle 01KMDKN3GHAC7B814PD3GB4THP")
    assert has_element?(view, "#event-#{matching_id}", "llm.edit")
    refute has_element?(view, "#event-#{other_id}")
  end

  defp insert_event(attrs) do
    id = Ecto.UUID.generate()
    dumped_id = Ecto.UUID.dump!(id)

    Repo.insert_all("events", [
      %{
        id: dumped_id,
        event: attrs[:event],
        measurements: Map.get(attrs, :measurements, %{}),
        metadata: Map.get(attrs, :metadata, %{}),
        inserted_at: Map.get(attrs, :inserted_at, DateTime.utc_now()),
        span_id: Map.get(attrs, :span_id),
        parent_id: Map.get(attrs, :parent_id)
      }
    ])

    id
  end
end
