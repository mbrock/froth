defmodule FrothWeb.TelemetryLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "legacy telemetry route redirects to follow", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/froth/follow"}}} = live(conn, ~p"/froth/telemetry")
  end
end
