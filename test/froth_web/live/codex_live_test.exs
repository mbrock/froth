defmodule FrothWeb.CodexLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Froth.Codex.Event
  alias Froth.Repo

  test "route without session id renders sessions index", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex")

    assert has_element?(view, "#codex-refresh-sessions")
    assert has_element?(view, "#codex-new-session")
  end

  test "route without session id lists persisted sessions", %{conn: conn} do
    session_id = "s_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    Repo.insert!(%Event{
      session_id: session_id,
      entry_id: "entry-1",
      sequence: 1,
      kind: "user",
      body: "hello from test",
      metadata: %{}
    })

    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex")

    assert has_element?(view, ~s|a[href="/froth/mini/codex/#{session_id}"]|)
  end
end
