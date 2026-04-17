defmodule FrothWeb.FollowLiveTest do
  use FrothWeb.ConnCase, async: true

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

    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    assert has_element?(view, "#follow-reader")
    assert has_element?(view, "#follow-mode-smart")
    assert has_element?(view, "#follow-entry-#{id}", "read_tool_transcript")
    assert has_element?(view, "#follow-entry-#{id}", "completed")
    assert has_element?(view, "#follow-entry-#{id}", "tool")

    view
    |> element("#follow-entry-#{id}")
    |> render_click()

    assert has_element?(view, "#follow-pin-cycle-#{id}")
    assert has_element?(view, "#follow-entry-#{id}", "read_tool_transcript")
    assert has_element?(view, "#follow-entry-#{id}", "completed")
  end

  test "raw mode reveals entries hidden in smart mode", %{conn: conn} do
    id =
      insert_event(%{
        event: "froth.llm.edit",
        metadata: %{
          "provider" => "anthropic",
          "op" => "append",
          "resource_id" => "message/blocks/0"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    refute has_element?(view, "#follow-entry-#{id}")

    view
    |> element("#follow-mode-raw")
    |> render_click()

    assert_patch(view, ~p"/froth/follow?mode=raw")
    assert has_element?(view, "#follow-entry-#{id}", "froth.llm.edit")
    assert has_element?(view, "#follow-entry-#{id}", "provider=anthropic")
  end

  test "errors mode focuses the timeline on failures and warnings", %{conn: conn} do
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
        event: "froth.agent.control.outcome",
        metadata: %{
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP",
          "outcome" => "tool_error",
          "tool_name" => "run_shell",
          "error" => "tool timed out after 30000ms"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    view
    |> element("#follow-mode-errors")
    |> render_click()

    assert_patch(view, ~p"/froth/follow?mode=errors")
    assert has_element?(view, "#follow-entry-#{error_id}", "tool error")
    refute has_element?(view, "#follow-entry-#{ok_id}")
  end

  test "cycle pinning narrows the timeline to one run", %{conn: conn} do
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

    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    view
    |> element("#follow-entry-#{matching_id}")
    |> render_click()

    view
    |> element("#follow-pin-cycle-#{matching_id}")
    |> render_click()

    assert_patch(view, ~p"/froth/follow?cycle=01KMDKN3GHAC7B814PD3GB4THP")
    assert has_element?(view, "#follow-reader", "cycle #{String.slice(cycle_id, 0, 12)}")
    assert has_element?(view, "#follow-entry-#{matching_id}")
    refute has_element?(view, "#follow-entry-#{other_id}")
  end

  test "query params restore a scoped raw view", %{conn: conn} do
    cycle_id = "01KMDKN3GHAC7B814PD3GB4THP"

    matching_id =
      insert_event(%{
        event: "froth.llm.edit",
        metadata: %{
          "provider" => "anthropic",
          "cycle_id" => cycle_id
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
      live(conn, ~p"/froth/follow?cycle=01KMDKN3GHAC7B814PD3GB4THP&mode=raw")

    assert has_element?(view, "#follow-reader", "cycle #{String.slice(cycle_id, 0, 12)}")
    assert has_element?(view, "#follow-entry-#{matching_id}", "froth.llm.edit")
    refute has_element?(view, "#follow-entry-#{other_id}")
  end

  test "live telemetry appends new matching entries", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/froth/follow")

    send(
      view.pid,
      {:telemetry_event, [:froth, :agent, :tool, :completed], %{"duration_ms" => 17},
       %{tool_name: "live_echo", cycle_id: "01LIVECYCLE00000000000000"}}
    )

    assert has_element?(view, "#follow-entries", "live_echo")
    assert has_element?(view, "#follow-entries", "completed")
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
