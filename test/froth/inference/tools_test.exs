defmodule Froth.Inference.ToolsTest do
  use ExUnit.Case, async: false

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Task
  alias Froth.TaskEvent
  alias Froth.TaskTelegramLink
  alias Froth.Telegram.CycleLink

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "read_tool_transcript includes prior cycle transcript and linked task output" do
    bot_id = "charlie"
    chat_id = unique_chat_id()
    task_id = "eval:test:#{System.unique_integer([:positive])}"

    user_msg =
      Repo.insert!(%Message{
        role: :user,
        content:
          Message.wrap([
            %{"type" => "text", "text" => "<new_messages>hello</new_messages>"}
          ])
      })

    agent_msg =
      Repo.insert!(%Message{
        role: :agent,
        content:
          Message.wrap([
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "elixir_eval",
              "input" => %{"code" => "IO.puts(\"hi\")"}
            }
          ]),
        parent_id: user_msg.id
      })

    result_msg =
      Repo.insert!(%Message{
        role: :user,
        content:
          Message.wrap([
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_1",
              "content" => "Session: eval_session_test\n\n:ok"
            }
          ]),
        parent_id: agent_msg.id
      })

    cycle = Repo.insert!(%Cycle{})
    Repo.insert!(%Agent.Event{cycle_id: cycle.id, head_id: result_msg.id, seq: 0})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: bot_id,
      chat_id: chat_id,
      reply_to: 123
    })

    Repo.insert!(
      Task.changeset(%Task{}, %{
        task_id: task_id,
        type: "eval",
        status: "completed",
        label: "IO.puts(\"hi\")",
        metadata: %{"session_id" => "eval_session_test"}
      })
    )

    Repo.insert!(
      TaskTelegramLink.changeset(%TaskTelegramLink{}, %{
        task_id: task_id,
        bot_id: bot_id,
        chat_id: chat_id
      })
    )

    Repo.insert!(
      TaskEvent.changeset(%TaskEvent{}, %{
        task_id: task_id,
        sequence: 1,
        kind: "stdout",
        content: "hello from eval\n",
        emitted_at: DateTime.utc_now()
      })
    )

    {:ok, transcript} =
      Tools.execute(
        "read_tool_transcript",
        %{
          "cycle_id" => cycle.id,
          "task_output_lines" => 20,
          "include_messages" => true
        },
        chat_id,
        bot_id: bot_id,
        session_id: "charlie"
      )

    assert transcript =~ "cycle #{cycle.id}"
    assert transcript =~ "tool_use elixir_eval"
    assert transcript =~ "[#{task_id}] type=eval"
    assert transcript =~ "hello from eval"
  end

  test "read_tool_transcript returns not found message for unknown cycle id" do
    chat_id = unique_chat_id()

    {:ok, result} =
      Tools.execute(
        "read_tool_transcript",
        %{"cycle_id" => Ecto.ULID.generate()},
        chat_id,
        bot_id: "charlie",
        session_id: "charlie"
      )

    assert result =~ "No cycle found"
  end

  test "look is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "look"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["message_id"]
  end

  test "look validates message references before trying telegram download" do
    chat_id = unique_chat_id()

    assert {:error, message} =
             Tools.execute(
               "look",
               %{"message_id" => "msg:not_a_number"},
               chat_id,
               bot_id: "charlie",
               session_id: "charlie"
             )

    assert message =~ "Invalid message_id"
  end

  defp unique_chat_id do
    9_000_000_000 + System.unique_integer([:positive])
  end
end
