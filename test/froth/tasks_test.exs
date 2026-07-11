defmodule Froth.TasksTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Froth.{Repo, TaskTelegramLink, Tasks}

  defmodule FakeBot do
    use GenServer

    def start_link(opts) when is_list(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, test_pid, name: name)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_cast(message, test_pid) do
      send(test_pid, {:fake_bot_cast, message})
      {:noreply, test_pid}
    end
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "listing tasks reconciles stale process-backed records" do
    bot_id = "bot-#{System.unique_integer([:positive])}"
    task_id = Tasks.generate_id("shell")

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "shell",
               label: "orphaned command"
             })

    assert :ok = Tasks.start(task_id)
    assert {:ok, _link} = Tasks.link_telegram(task_id, bot_id)

    Repo.update_all(
      from(task in Froth.Task, where: task.task_id == ^task_id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)]
    )

    assert [%{task_id: ^task_id, status: "stopped"}] =
             Tasks.list_recent(bot_id, 1)

    assert Tasks.get(task_id).metadata["stale"] == true
  end

  test "completion notifications send a synthetic wakeup message the bot can consume" do
    bot_id = "bot-#{System.unique_integer([:positive])}"
    chat_id = 4242
    task_id = Tasks.generate_id("codex")

    start_supervised!(
      {FakeBot, test_pid: self(), name: Froth.Telegram.Bots.via(bot_id)}
    )

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "codex",
               label: "Implement RFC-0009",
               metadata: %{session_id: "codex-session-1"}
             })

    assert %Froth.TaskEvent{} =
             Tasks.append_output(task_id, "task output preview")

    assert {:ok, _link} =
             Tasks.subscribe_telegram(task_id, bot_id, chat_id,
               message_id: 999
             )

    assert :ok = Tasks.complete(task_id)

    assert_receive {:fake_bot_cast,
                    {:start_inference_session,
                     %{
                       "chat_id" => ^chat_id,
                       "reply_to_override" => 999,
                       "sender_id" => 0,
                       "date" => date,
                       "content" => %{"text" => %{"text" => text}}
                     }}},
                   1_000

    assert is_integer(date)
    assert text =~ "[Task completed] #{task_id} completed."
    assert text =~ "task output preview"

    assert Repo.exists?(
             from(link in TaskTelegramLink,
               where:
                 link.task_id == ^task_id and link.bot_id == ^bot_id and
                   link.chat_id == ^chat_id and
                   not is_nil(link.notified_at)
             )
           )
  end

  test "failure notifications use the task status label and status fallback text" do
    bot_id = "bot-#{System.unique_integer([:positive])}"
    chat_id = 5252
    task_id = Tasks.generate_id("shell")

    start_supervised!(
      {FakeBot, test_pid: self(), name: Froth.Telegram.Bots.via(bot_id)}
    )

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "shell",
               label: "false"
             })

    assert {:ok, _link} = Tasks.subscribe_telegram(task_id, bot_id, chat_id)
    assert :ok = Tasks.fail(task_id, "boom")

    assert_receive {:fake_bot_cast,
                    {:start_inference_session,
                     %{
                       "chat_id" => ^chat_id,
                       "content" => %{"text" => %{"text" => text}}
                     }}},
                   1_000

    assert text =~ "[Task failed] #{task_id} failed."
    assert text =~ "failed: boom"
  end

  describe "append_output/2 with non-text-safe bytes" do
    # task_events.content is a Postgres text column, which rejects
    # NUL bytes and invalid UTF-8. The shell GenServer appends raw
    # stdout chunks directly, so a `cat foo.png` used to crash the
    # GenServer on the first chunk — taking the whole task with it
    # and leaving the agent with an empty task_output. These tests
    # lock in the sanitizer that replaces unsafe chunks with a
    # human-readable placeholder.

    test "binary stdout lands as a [binary: …] placeholder event" do
      task_id = Tasks.generate_id("shell")

      {:ok, _} =
        Tasks.create(%{
          task_id: task_id,
          type: "shell",
          label: "cat logo.png"
        })

      png = <<0x89, "PNG\r\n", 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
      event = Tasks.append_output(task_id, png)

      assert %Froth.TaskEvent{kind: "stdout"} = event
      assert event.content == "[binary: image/png #{byte_size(png)} bytes]\n"

      [stored] = Tasks.recent_output(task_id, 10)
      assert stored.content == event.content
    end

    test "NUL-bearing stdout without a known signature falls back to octet-stream" do
      task_id = Tasks.generate_id("shell")

      {:ok, _} =
        Tasks.create(%{task_id: task_id, type: "shell", label: "printf ..."})

      chunk = <<0xAB, 0xCD, 0x00, 0x01, 0x02>>
      event = Tasks.append_output(task_id, chunk)

      assert event.content ==
               "[binary: application/octet-stream #{byte_size(chunk)} bytes]\n"
    end

    test "text stdout passes through unchanged" do
      task_id = Tasks.generate_id("shell")

      {:ok, _} =
        Tasks.create(%{task_id: task_id, type: "shell", label: "echo hello"})

      event = Tasks.append_output(task_id, "hello world\n")

      assert event.content == "hello world\n"
    end
  end
end
