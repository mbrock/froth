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
         active_turn_id: "turn-live-1",
         active_assistant_entry_id: "entry-1",
         runtime: %{model: "gpt-5.4", reasoning_effort: "xhigh", sandbox: "danger-full-access"},
         available_models: [
           %{
             "displayName" => "gpt-5.4",
             "hidden" => false,
             "id" => "gpt-5.4",
             "isDefault" => true,
             "model" => "gpt-5.4"
           },
           %{
             "displayName" => "GPT-5.4-Mini",
             "hidden" => false,
             "id" => "gpt-5.4-mini",
             "isDefault" => false,
             "model" => "gpt-5.4-mini"
           }
         ],
         token_usage: %{last: %{totalTokens: 198_500}, total: %{totalTokens: 9_400_000}},
         rate_limits: %{primary: %{usedPercent: 14}, secondary: %{usedPercent: 28}},
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
             body: "working (turn_019d2785-6b2)",
             sequence: 2
           },
           %{
             id: "entry-3",
             kind: :status,
             body:
               "received turn/plan/updated %{\"EXPLANATION\" => \"Tighten the mobile layout\", " <>
                 "\"plan\" => [%{\"step\" => \"Add follow toggle\", \"status\" => \"completed\"}, " <>
                 "%{\"step\" => \"Render markdown\", \"status\" => \"in_progress\"}]}",
             sequence: 3
           },
           %{
             id: "entry-4",
             kind: :tool,
             body: "rg --files lib",
             status: "ok",
             output: "lib/froth_web/live/codex_live.ex\nlib/froth/codex/session.ex",
             sequence: 4
           }
         ]
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex/#{session_id}")

    assert has_element?(view, "#codex-working-dock")
    assert has_element?(view, "#codex-interrupt", "Stop")
    assert has_element?(view, "#codex-reasoning-effort option[selected][value='xhigh']")
    refute has_element?(view, "#codex-prompt-form")
    refute has_element?(view, "#codex-upload-image")
    refute has_element?(view, "#codex-model-form")
    assert has_element?(view, "#entry-1 strong", "Bold")
    assert has_element?(view, "#entry-1 .codex-inline-spinner")
    refute has_element?(view, "#entry-2")
    assert has_element?(view, "#entry-3", "Tighten the mobile layout")
    assert has_element?(view, "#entry-3", "Add follow toggle")
    assert has_element?(view, "#entry-3", "Render markdown")
    assert has_element?(view, "#entry-4", "command")
    assert has_element?(view, "#entry-4", "rg --files lib")
    assert has_element?(view, "#entry-4", "output")
    assert has_element?(view, "#entry-4", "lib/froth_web/live/codex_live.ex")
    refute has_element?(view, "#codex-close")

    view
    |> form("#codex-reasoning-form", reasoning: %{effort: "high"})
    |> render_change()

    assert has_element?(view, "#codex-reasoning-effort option[selected][value='high']")
  end

  test "refreshes model options when a session snapshot is missing them", %{conn: conn} do
    session_id = "s_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    start_supervised!(
      {FakeCodexSession,
       session_id: session_id,
       snapshot: %{
         status: :ready,
         thread_id: "thread-#{session_id}",
         runtime: %{model: "gpt-5.4-mini"},
         available_models: []
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex/#{session_id}")

    assert has_element?(view, "#codex-prompt-form")
    assert has_element?(view, "#codex-upload-image")
    assert has_element?(view, "#codex-send")
    refute has_element?(view, "#codex-working-dock")

    {:ok, snapshot} = FakeCodexSession.snapshot(session_id)
    assert snapshot.available_models != []
  end

  test "pasted image uploads can be submitted with the prompt form", %{conn: conn} do
    session_id = "s_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    upload_dir = Path.join([File.cwd!(), "priv", "static", "codex_uploads", session_id])

    on_exit(fn -> File.rm_rf(upload_dir) end)

    start_supervised!(
      {FakeCodexSession,
       session_id: session_id,
       snapshot: %{
         status: :ready,
         thread_id: "thread-#{session_id}",
         entries: []
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/froth/mini/codex/#{session_id}")

    upload =
      file_input(view, "#codex-prompt-form", :images, [
        %{
          last_modified: 0,
          name: "paste.png",
          content: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>,
          type: "image/png"
        }
      ])

    _ = render_upload(upload, "paste.png")
    assert has_element?(view, "#codex-image-staging")

    view
    |> form("#codex-prompt-form", codex: %{prompt: ""})
    |> render_submit()

    assert has_element?(view, "#codex-feed-list img[src^=\"/froth/codex_uploads/\"]")
  end
end
