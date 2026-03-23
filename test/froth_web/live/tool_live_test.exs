defmodule FrothWeb.ToolLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.Repo

  test "shows stop affordance for a loaded cycle even when transcript looks complete", %{
    conn: conn
  } do
    cycle = Repo.insert!(%Cycle{})
    message = Repo.insert!(Message.agent("complete enough to look done"))
    Agent.append_event(cycle, %{head_id: message.id, message_id: message.id})

    {:ok, view, _html} = live(conn, ~p"/froth/mini/tool/cycle_missingbot_#{cycle.id}")

    assert has_element?(view, "#loop-stop")
    assert has_element?(view, "#loop-close")

    view
    |> element("#loop-stop")
    |> render_click()

    refute has_element?(view, "#loop-stop")
    assert has_element?(view, "#loop-now-dock", "stop requested")
  end
end
