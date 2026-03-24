defmodule Froth.Codex.TaskWatcherTest do
  use ExUnit.Case, async: false

  alias Froth.{Repo, Tasks}
  alias Froth.Codex.TaskWatcher
  alias Froth.TestSupport.FakeCodexSession

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

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
        {TaskWatcher, task_id: task_id, session_id: session_id, session_module: FakeCodexSession}
      )

    ref = Process.monitor(watcher)
    {:ok, snapshot} = FakeCodexSession.snapshot(session_id)

    assert :ok = FakeCodexSession.set_snapshot(session_id, %{snapshot | active_turn_id: "turn-1"})
    assert :ok = FakeCodexSession.set_snapshot(session_id, %{snapshot | active_turn_id: nil})

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
        {TaskWatcher, task_id: task_id, session_id: session_id, session_module: FakeCodexSession}
      )

    ref = Process.monitor(watcher)
    assert :ok = FakeCodexSession.crash(session_id, :boom)

    assert_receive {:task_event, ^task_id, event}, 1_000
    assert event.kind == "status"
    assert event.content =~ "failed: Codex session exited: :boom"
    assert %Froth.Task{status: "failed"} = Tasks.get(task_id)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 1_000
  end
end
