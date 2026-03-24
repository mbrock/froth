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
    Agent.append_event(cycle, %{head_id: result_msg.id, message_id: result_msg.id})

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

  test "web_search is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "web_search"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["query"]
  end

  test "web_search executes triangulated search and returns tool payload" do
    original_grok = Application.get_env(:froth, Froth.Grok, [])
    original_openai = Application.get_env(:froth, Froth.OpenAI, [])
    original_gemini = Application.get_env(:froth, Froth.Gemini, [])
    original_stream_fun = Application.get_env(:froth, :llm_stream_fun)
    original_stream_single_fun = Application.get_env(:froth, :llm_stream_single_fun)

    on_exit(fn ->
      Application.put_env(:froth, Froth.Grok, original_grok)
      Application.put_env(:froth, Froth.OpenAI, original_openai)
      Application.put_env(:froth, Froth.Gemini, original_gemini)

      if is_nil(original_stream_fun) do
        Application.delete_env(:froth, :llm_stream_fun)
      else
        Application.put_env(:froth, :llm_stream_fun, original_stream_fun)
      end

      if is_nil(original_stream_single_fun) do
        Application.delete_env(:froth, :llm_stream_single_fun)
      else
        Application.put_env(:froth, :llm_stream_single_fun, original_stream_single_fun)
      end
    end)

    Application.put_env(:froth, Froth.Grok, api_key: "test-grok")
    Application.put_env(:froth, Froth.OpenAI, api_key: "test-openai")
    Application.put_env(:froth, Froth.Gemini, api_key: "test-gemini")

    Application.put_env(:froth, :llm_stream_fun, fn request, _on_event, _opts ->
      text = "Provider #{inspect(request.provider)} saw https://example.test/source"

      {:ok,
       %{
         text: text,
         content: [%{"type" => "text", "text" => text}],
         stop_reason: "stop",
         usage: %{},
         model: request.model,
         message_id: "resp_test"
       }}
    end)

    Application.put_env(:froth, :llm_stream_single_fun, fn _messages, _on_event, _opts ->
      json =
        ~s({"collated":"All three providers returned a grounded source.","agreement":1.0,"single_source_claims":[]})

      {:ok,
       %{
         text: json,
         content: [%{"type" => "text", "text" => json}],
         stop_reason: "end_turn",
         usage: %{},
         model: "claude-sonnet-4-20250514",
         message_id: "msg_collate"
       }}
    end)

    assert {:ok, payload} =
             Tools.execute(
               "web_search",
               %{"query" => "Kharg Island"},
               unique_chat_id(),
               bot_id: "charlie",
               session_id: "charlie"
             )

    assert payload["collated"] == "All three providers returned a grounded source."
    assert payload["agreement"] == 1.0
    assert payload["single_source_claims"] == []
    assert Map.keys(payload["providers"]) == ["gemini", "grok", "openai"]
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

  test "read_tool_transcript includes linked video tasks" do
    bot_id = "charlie"
    chat_id = unique_chat_id()
    task_id = "video:test:#{System.unique_integer([:positive])}"

    user_msg =
      Repo.insert!(%Message{
        role: :user,
        content: Message.wrap([%{"type" => "text", "text" => "make it a reel"}])
      })

    agent_msg =
      Repo.insert!(%Message{
        role: :agent,
        content:
          Message.wrap([
            %{
              "type" => "tool_use",
              "id" => "toolu_video",
              "name" => "elixir_eval",
              "input" => %{"code" => "Froth.Video.from_podcast(\"abc\")"}
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
              "tool_use_id" => "toolu_video",
              "content" => "Started podcast video task task_id=#{task_id}"
            }
          ]),
        parent_id: agent_msg.id
      })

    cycle = Repo.insert!(%Cycle{})
    Agent.append_event(cycle, %{head_id: result_msg.id, message_id: result_msg.id})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: bot_id,
      chat_id: chat_id,
      reply_to: 456
    })

    Repo.insert!(
      Task.changeset(%Task{}, %{
        task_id: task_id,
        type: "video",
        status: "completed",
        label: "podcast video abc",
        metadata: %{"batch_id" => "abc", "output_path" => "/tmp/abc.mp4"}
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
        content: "Podcast video abc completed: /tmp/abc.mp4\n",
        emitted_at: DateTime.utc_now()
      })
    )

    {:ok, transcript} =
      Tools.execute(
        "read_tool_transcript",
        %{"cycle_id" => cycle.id, "task_output_lines" => 20, "include_messages" => true},
        chat_id,
        bot_id: bot_id,
        session_id: "charlie"
      )

    assert transcript =~ "[#{task_id}] type=video"
    assert transcript =~ "/tmp/abc.mp4"
  end

  test "read_tool_transcript keeps oversized transcripts bounded" do
    bot_id = "charlie"
    chat_id = unique_chat_id()
    task_id = "shell:test:#{System.unique_integer([:positive])}"
    huge_chunk = String.duplicate("abcdefghij", 4_000)

    user_msg =
      Repo.insert!(%Message{
        role: :user,
        content: Message.wrap([%{"type" => "text", "text" => huge_chunk}])
      })

    agent_msg =
      Repo.insert!(%Message{
        role: :agent,
        content:
          Message.wrap([
            %{
              "type" => "tool_use",
              "id" => "toolu_huge",
              "name" => "run_shell",
              "input" => %{"command" => "printf huge"}
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
              "tool_use_id" => "toolu_huge",
              "content" => huge_chunk
            }
          ]),
        parent_id: agent_msg.id
      })

    cycle = Repo.insert!(%Cycle{})
    Agent.append_event(cycle, %{head_id: result_msg.id, message_id: result_msg.id})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: bot_id,
      chat_id: chat_id,
      reply_to: 789
    })

    Repo.insert!(
      Task.changeset(%Task{}, %{
        task_id: task_id,
        type: "shell",
        status: "completed",
        label: "printf huge"
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
        content: huge_chunk,
        emitted_at: DateTime.utc_now()
      })
    )

    {:ok, transcript} =
      Tools.execute(
        "read_tool_transcript",
        %{"cycle_id" => cycle.id, "include_messages" => true, "task_output_lines" => 200},
        chat_id,
        bot_id: bot_id,
        session_id: "charlie"
      )

    assert String.length(transcript) <= 20_080
    refute transcript =~ huge_chunk
  end

  defp unique_chat_id do
    9_000_000_000 + System.unique_integer([:positive])
  end
end
