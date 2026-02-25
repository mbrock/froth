defmodule FrothWeb.PageControllerTest do
  use FrothWeb.ConnCase, async: true

  test "GET /froth renders analyses page", %{conn: conn} do
    conn = get(conn, ~p"/froth")
    html = html_response(conn, 200)
    assert html =~ "analyses-page"
  end
end
