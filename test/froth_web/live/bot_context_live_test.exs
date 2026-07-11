defmodule FrothWeb.BotContextLiveTest do
  use FrothWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders bot context as part of the shared memory reader", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/froth/bot-context")

    assert has_element?(view, "#bot-context-reader")
    assert has_element?(view, "#bot-context-system")
    assert has_element?(view, "#bot-context-parts")

    assert has_element?(
             view,
             ~s(#memory-reader-nav a[aria-current="page"][href="/froth/bot-context"])
           )

    assert has_element?(
             view,
             ~s(#memory-reader-nav a[href="/froth/summaries"])
           )

    assert has_element?(view, ~s(#memory-reader-nav a[href="/froth/weekly"]))
  end
end
