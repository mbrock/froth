defmodule Froth.TasksTest do
  use ExUnit.Case, async: false

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
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "completion notifications send a synthetic wakeup message the bot can consume" do
    bot_id = "bot-#{System.unique_integer([:positive])}"
    chat_id = 4242
    task_id = Tasks.generate_id("codex")

    start_supervised!({FakeBot, test_pid: self(), name: Froth.Telegram.Bots.via(bot_id)})

    assert {:ok, _task} =
             Tasks.create(%{
               task_id: task_id,
               type: "codex",
               label: "Implement RFC-0009",
               metadata: %{session_id: "codex-session-1"}
             })

    assert %Froth.TaskEvent{} = Tasks.append_output(task_id, "task output preview")
    assert {:ok, _link} = Tasks.subscribe_telegram(task_id, bot_id, chat_id, message_id: 999)
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
                 link.task_id == ^task_id and link.bot_id == ^bot_id and link.chat_id == ^chat_id and
                   not is_nil(link.notified_at)
             )
           )
  end

  test "failure notifications use the task status label and status fallback text" do
    bot_id = "bot-#{System.unique_integer([:positive])}"
    chat_id = 5252
    task_id = Tasks.generate_id("shell")

    start_supervised!({FakeBot, test_pid: self(), name: Froth.Telegram.Bots.via(bot_id)})

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
end
