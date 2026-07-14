defmodule Froth.Codex.TaskWatcherTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Tasks
  alias Froth.Codex.TaskWatcher
  alias Froth.TestSupport.FakeCodexSession

  test "completes the Froth task when the Codex session returns to idle after a turn" do
    session_id = "fake-codex-#{System.unique_integer([:positive])}"
    task_id = Tasks.generate_id("codex")

    start_supervised!({FakeCodexSession, session_id: session_id})

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "codex",
               label: "Watcher completion test",
               metadata: %{session_id: session_id}
             })

    assert :ok = Tasks.subscribe(task_id)

    watcher =
      start_supervised!(
        {TaskWatcher,
         task_id: task_id,
         session_id: session_id,
         session_module: FakeCodexSession,
         caller: self()}
      )

    ref = Process.monitor(watcher)
    {:ok, snapshot} = FakeCodexSession.snapshot(session_id)

    assert :ok =
             FakeCodexSession.set_snapshot(session_id, %{
               snapshot
               | active_turn_id: "turn-1"
             })

    assert :ok =
             FakeCodexSession.set_snapshot(session_id, %{
               snapshot
               | active_turn_id: nil
             })

    assert_receive {:task_event, ^task_id, event}, 1_000
    assert event.kind == "status"
    assert event.content == "completed"
    assert %Froth.Task{status: "completed"} = Tasks.get(task_id)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
  end

  test "fails the Froth task when the Codex session exits" do
    session_id = "fake-codex-#{System.unique_integer([:positive])}"
    task_id = Tasks.generate_id("codex")

    start_supervised!({FakeCodexSession, session_id: session_id})

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "codex",
               label: "Watcher failure test",
               metadata: %{session_id: session_id}
             })

    assert :ok = Tasks.subscribe(task_id)

    watcher =
      start_supervised!(
        {TaskWatcher,
         task_id: task_id,
         session_id: session_id,
         session_module: FakeCodexSession,
         caller: self()}
      )

    ref = Process.monitor(watcher)
    assert :ok = FakeCodexSession.crash(session_id, :boom)

    assert_receive {:task_event, ^task_id, event}, 1_000
    assert event.kind == "status"
    assert event.content =~ "failed: Codex session exited: :boom"
    assert %Froth.Task{status: "failed"} = Tasks.get(task_id)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
  end

  test "relays each completed assistant message as a quoted Telegram update" do
    session_id = "fake-codex-#{System.unique_integer([:positive])}"
    task_id = Tasks.generate_id("codex")
    bot_id = start_fake_session()
    chat_id = System.unique_integer([:positive])
    reply_to = System.unique_integer([:positive])

    start_supervised!({FakeCodexSession, session_id: session_id})

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "codex",
               label: "Progress relay test",
               metadata: %{session_id: session_id}
             })

    assert {:ok, _link} =
             Tasks.subscribe_telegram(task_id, bot_id, chat_id,
               message_id: reply_to
             )

    start_supervised!(
      {TaskWatcher,
       task_id: task_id,
       session_id: session_id,
       session_module: FakeCodexSession,
       caller: self()}
    )

    {:ok, snapshot} = FakeCodexSession.snapshot(session_id)

    assert :ok =
             FakeCodexSession.set_snapshot(session_id, %{
               snapshot
               | active_turn_id: "turn-1",
                 entries: [
                   %{
                     id: "assistant-1",
                     sequence: 1,
                     kind: :assistant,
                     body: "The implementation",
                     completed: false
                   }
                 ]
             })

    refute_receive {:telegram_call, _payload}, 100

    assert :ok =
             FakeCodexSession.set_snapshot(session_id, %{
               snapshot
               | active_turn_id: "turn-1",
                 entries: [
                   %{
                     id: "assistant-1",
                     sequence: 1,
                     kind: :assistant,
                     body: "The implementation is ready. 🚀",
                     completed: true
                   }
                 ]
             })

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "reply_to" => %{
                        "message_id" => ^reply_to
                      },
                      "input_message_content" => %{
                        "text" => %{
                          "text" => "Codex\nThe implementation is ready. 🚀",
                          "entities" => entities
                        }
                      }
                    }}

    assert Enum.any?(entities, fn entity ->
             get_in(entity, ["type", "@type"]) ==
               "textEntityTypeBlockQuote"
           end)

    quote_entity =
      Enum.find(entities, fn entity ->
        get_in(entity, ["type", "@type"]) == "textEntityTypeBlockQuote"
      end)

    assert quote_entity["length"] ==
             String.length("The implementation is ready. 🚀") + 1

    assert :ok = FakeCodexSession.set_snapshot(session_id, snapshot)
    refute_receive {:telegram_call, _payload}, 100
  end
end
