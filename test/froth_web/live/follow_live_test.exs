defmodule FrothWeb.FollowLiveTest do
  use FrothWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Froth.Repo

  test "renders recent events from the events table", %{conn: conn} do
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

    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    assert has_element?(view, "#follow-reader")

    assert has_element?(
             view,
             "#follow-entry-#{id}",
             "froth.agent.tool.completed"
           )

    assert has_element?(
             view,
             "#follow-entry-#{id}",
             "tool_name=read_tool_transcript"
           )
  end

  test "errors mode hides non-error rows", %{conn: conn} do
    ok_id =
      insert_event(%{
        event: "froth.agent.tool.completed",
        metadata: %{
          "tool_name" => "read_tool_transcript",
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP"
        }
      })

    error_id =
      insert_event(%{
        event: "froth.agent.tool.failed",
        metadata: %{
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP",
          "tool_name" => "run_shell",
          "error" => "tool timed out after 30000ms"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    view
    |> element("#follow-mode-errors")
    |> render_click()

    assert_patch(view, ~p"/froth/follow?mode=errors")
    assert has_element?(view, "#follow-entry-#{error_id}")
    refute has_element?(view, "#follow-entry-#{ok_id}")
  end

  test "cycle filter narrows the feed", %{conn: conn} do
    cycle_id = "01KMDKN3GHAC7B814PD3GB4THP"

    matching_id =
      insert_event(%{
        event: "froth.agent.tool.completed",
        metadata: %{
          "tool_name" => "read_tool_transcript",
          "cycle_id" => cycle_id
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

    {:ok, view, _html} = live(conn, ~p"/froth/follow?cycle=#{cycle_id}")

    assert has_element?(view, "#follow-entry-#{matching_id}")
    refute has_element?(view, "#follow-entry-#{other_id}")
  end

  test "live events arriving via pub/sub append to the feed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    event = %Froth.Event{
      id: Ecto.UUID.generate(),
      event: "froth.agent.tool.completed",
      measurements: %{"duration_ms" => 17},
      metadata: %{
        "tool_name" => "live_echo",
        "cycle_id" => "01LIVECYCLE00000000000000"
      },
      inserted_at: DateTime.utc_now()
    }

    send(view.pid, {:event, event})

    assert has_element?(view, "#follow-entries", "live_echo")
    assert has_element?(view, "#follow-entries", "froth.agent.tool.completed")
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
