defmodule FrothWeb.PageControllerTest do
  use FrothWeb.ConnCase, async: true

  test "GET /froth renders the landing page", %{conn: conn} do
    conn = get(conn, ~p"/froth")
    html = html_response(conn, 200)
    {:ok, document} = Floki.parse_document(html)

    assert Floki.find(document, "#froth-home") != []
    assert Floki.find(document, "#froth-hero") != []
    assert Floki.find(document, "#froth-primary-links") != []
    assert Floki.find(document, "#froth-secondary-links") != []
    assert Floki.find(document, "#froth-dashboard") != []
    assert Floki.find(document, "#froth-recent-tasks") != []
    assert Floki.find(document, "#froth-recent-analyses") != []

    assert Floki.find(
             document,
             ~s(#froth-link-codex[href="/froth/mini/codex"])
           ) != []

    assert Floki.find(document, ~s(#froth-link-follow[href="/froth/follow"])) !=
             []

    assert Floki.find(
             document,
             ~s(#froth-link-chronicle[href="/froth/summaries"])
           ) != []

    assert Floki.find(
             document,
             ~s(#froth-link-bot-context[href="/froth/bot-context"])
           ) != []

    assert Floki.find(
             document,
             ~s(#froth-link-analyses[href="/froth/analyses/day"])
           ) != []
  end
end
