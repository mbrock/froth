defmodule Froth.Codex.TaskTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.{Repo, Task, Tasks, TaskTelegramLink}
  alias Froth.Codex.Task, as: CodexTask
  alias Froth.TestSupport.FakeCodexSession

  test "run/2 creates and starts a tracked Froth task for the Codex session" do
    session_id = "fake-codex-#{System.unique_integer([:positive])}"

    start_supervised!({FakeCodexSession, session_id: session_id})

    assert {:ok, ^session_id} =
             CodexTask.run("Implement RFC-0009",
               session_id: session_id,
               session_module: FakeCodexSession
             )

    task = codex_task_for_session(session_id)
    assert %Task{status: "running", type: "codex"} = task
    assert task.label == "Implement RFC-0009"
    assert metadata_session_id(task.metadata) == session_id

    watcher = codex_watcher(session_id)
    ref = Process.monitor(watcher)

    assert :ok = Tasks.subscribe(task.task_id)

    {:ok, snapshot} = FakeCodexSession.snapshot(session_id)
    assert is_binary(snapshot.active_turn_id)

    assert :ok =
             FakeCodexSession.set_snapshot(session_id, %{
               snapshot
               | active_turn_id: nil
             })

    task_id = task.task_id

    assert_receive {:task_event, ^task_id, event}, 1_000
    assert event.kind == "status"
    assert event.content == "completed"
    assert %Task{status: "completed"} = Tasks.get(task_id)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
  end

  test "run/2 links Telegram notifications to the originating message" do
    session_id = "fake-codex-#{System.unique_integer([:positive])}"
    bot_id = start_fake_session()
    chat_id = System.unique_integer([:positive])
    reply_to = System.unique_integer([:positive])

    start_supervised!({FakeCodexSession, session_id: session_id})

    assert {:ok, ^session_id} =
             CodexTask.run("Build the thing",
               session_id: session_id,
               session_module: FakeCodexSession,
               bot_id: bot_id,
               chat_id: chat_id,
               reply_to: reply_to
             )

    task = codex_task_for_session(session_id)

    assert %TaskTelegramLink{
             task_id: task_id,
             bot_id: ^bot_id,
             chat_id: ^chat_id,
             message_id: ^reply_to,
             notify: true
           } = Repo.get_by!(TaskTelegramLink, task_id: task.task_id)

    assert task_id == task.task_id

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "reply_to" => %{
                        "message_id" => ^reply_to
                      }
                    }}

    watcher = codex_watcher(session_id)
    ref = Process.monitor(watcher)
    {:ok, snapshot} = FakeCodexSession.snapshot(session_id)

    assert :ok =
             FakeCodexSession.set_snapshot(session_id, %{
               snapshot
               | active_turn_id: nil
             })

    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
  end

  defp codex_task_for_session(session_id) do
    Repo.all(Task)
    |> Enum.find(fn task ->
      task.type == "codex" and
        metadata_session_id(task.metadata) == session_id
    end)
  end

  defp metadata_session_id(metadata) when is_map(metadata) do
    metadata[:session_id] || metadata["session_id"]
  end

  defp metadata_session_id(_metadata), do: nil

  defp codex_watcher(session_id) do
    Froth.Tasks.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {:undefined, pid, :worker, [Froth.Codex.TaskWatcher]} ->
        if :sys.get_state(pid).session_id == session_id, do: pid

      _ ->
        nil
    end)
  end
end
