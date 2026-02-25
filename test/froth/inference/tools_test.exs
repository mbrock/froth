defmodule Froth.Inference.ToolsTest do
  use ExUnit.Case, async: false

  alias Froth.Inference.InferenceSession
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Task
  alias Froth.TaskEvent
  alias Froth.TaskTelegramLink

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "read_tool_transcript includes prior loop transcript and linked task output" do
    bot_id = "charlie"
    chat_id = unique_chat_id()
    task_id = "eval:test:#{System.unique_integer([:positive])}"

    {:ok, inference_session} =
      %InferenceSession{}
      |> InferenceSession.changeset(%{
        bot_id: bot_id,
        chat_id: chat_id,
        reply_to: 123,
        status: "done",
        api_messages: [
          %{"role" => "user", "content" => "<new_messages>hello</new_messages>"},
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "toolu_1",
                "name" => "elixir_eval",
                "input" => %{"code" => "IO.puts(\"hi\")"}
              }
            ]
          },
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_1",
                "content" => "Session: eval_session_test\n\n:ok"
              }
            ]
          }
        ],
        tool_steps: [
          %{
            "at" => "2026-02-16T00:00:00Z",
            "kind" => "tool_queued",
            "data" => %{"name" => "elixir_eval", "tool_use_id" => "toolu_1", "ref" => "abcd1234"}
          }
        ]
      })
      |> Repo.insert()

    {:ok, _task} =
      %Task{}
      |> Task.changeset(%{
        task_id: task_id,
        type: "eval",
        status: "completed",
        label: "IO.puts(\"hi\")",
        metadata: %{"session_id" => "eval_session_test"}
      })
      |> Repo.insert()

    {:ok, _link} =
      %TaskTelegramLink{}
      |> TaskTelegramLink.changeset(%{
        task_id: task_id,
        bot_id: bot_id,
        chat_id: chat_id
      })
      |> Repo.insert()

    {:ok, _event_1} =
      %TaskEvent{}
      |> TaskEvent.changeset(%{
        task_id: task_id,
        sequence: 1,
        kind: "stdout",
        content: "hello from eval\n",
        emitted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, _event_2} =
      %TaskEvent{}
      |> TaskEvent.changeset(%{
        task_id: task_id,
        sequence: 2,
        kind: "status",
        content: "completed",
        emitted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, transcript} =
      Tools.execute(
        "read_tool_transcript",
        %{
          "inference_session_id" => inference_session.id,
          "task_output_lines" => 20,
          "include_api_messages" => true
        },
        chat_id,
        bot_id: bot_id,
        session_id: "charlie"
      )

    assert transcript =~ "inference_session ##{inference_session.id}"
    assert transcript =~ "tool_use elixir_eval"
    assert transcript =~ "[#{task_id}] type=eval"
    assert transcript =~ "hello from eval"
  end

  test "read_tool_transcript returns not found message for unknown session id in this chat" do
    chat_id = unique_chat_id()

    {:ok, result} =
      Tools.execute(
        "read_tool_transcript",
        %{"inference_session_id" => 9_999_999},
        chat_id,
        bot_id: "charlie",
        session_id: "charlie"
      )

    assert result =~ "No inference session found"
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
