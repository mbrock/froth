defmodule FrothWeb.CodexLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Froth.Codex.Event
  alias Froth.Repo
  alias Froth.TestSupport.FakeCodexSession

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

  test "session timeline stays visible across ordinary rerenders", %{conn: conn} do
    session_id = "s_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    start_supervised!(
      {FakeCodexSession,
       session_id: session_id,
       snapshot: %{
         status: :ready,
         thread_id: "thread-#{session_id}",
         entries: [
           %{
             id: "entry-1",
             kind: :assistant,
             body: "persisted timeline entry",
             sequence: 1
           }
         ]
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex/#{session_id}")

    assert has_element?(view, "#codex-feed-list > #entry-1")
    assert has_element?(view, "#entry-1 p", "persisted timeline entry")

    send(view.pid, :tick)
    _ = render(view)

    assert has_element?(view, "#codex-feed-list > #entry-1")
    assert has_element?(view, "#entry-1 p", "persisted timeline entry")
  end

  test "renders markdown messages and structured plan cards", %{conn: conn} do
    session_id = "s_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    start_supervised!(
      {FakeCodexSession,
       session_id: session_id,
       snapshot: %{
         status: :ready,
         thread_id: "thread-#{session_id}",
         entries: [
           %{
             id: "entry-1",
             kind: :assistant,
             body: "**Bold** message",
             sequence: 1
           },
           %{
             id: "entry-2",
             kind: :status,
             body:
               "received turn/plan/updated %{\"EXPLANATION\" => \"Tighten the mobile layout\", " <>
                 "\"plan\" => [%{\"step\" => \"Add follow toggle\", \"status\" => \"completed\"}, " <>
                 "%{\"step\" => \"Render markdown\", \"status\" => \"in_progress\"}]}",
             sequence: 2
           }
         ]
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex/#{session_id}")

    assert has_element?(view, "#codex-follow-tail")
    assert has_element?(view, "#entry-1 strong", "Bold")
    assert has_element?(view, "#entry-2", "Tighten the mobile layout")
    assert has_element?(view, "#entry-2", "Add follow toggle")
    assert has_element?(view, "#entry-2", "Render markdown")
  end
end
