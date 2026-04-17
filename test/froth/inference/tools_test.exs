defmodule Froth.Inference.ToolsTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.ApiKey
  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.Inference.Tools
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.LLM.Request
  alias Froth.Task
  alias Froth.TaskEvent
  alias Froth.TaskTelegramLink
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.PendingAsk

  test "specs_for_api does not expose MCP endpoints even when a Wolfram key is available" do
    Repo.insert!(%ApiKey{name: "wolfram", provider: "wolfram", key: "wolfram-token"})

    refute Enum.any?(Tools.specs_for_api(), &(&1["type"] == "mcp_endpoint"))
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

    final_agent_msg =
      Repo.insert!(%Message{
        role: :agent,
        content: Message.wrap([%{"type" => "text", "text" => "Eval says hi"}]),
        parent_id: result_msg.id
      })

    cycle = Repo.insert!(%Cycle{})
    Agent.append_event(cycle, %{head_id: final_agent_msg.id, message_id: final_agent_msg.id})

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
    assert transcript =~ "Final reply:"
    assert transcript =~ "Eval says hi"
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

  test "ask is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "ask"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["question"]
  end

  test "canonical tool descriptions include guidance previously duplicated in Charlie prompt" do
    specs = Map.new(Tools.specs_for_api(), &{&1["name"], &1})

    assert specs["send_message"]["description"] =~
             "one paragraph or one finished thought at a time"

    assert specs["ask"]["description"] =~ "pause the current agent cycle"
    assert specs["read_log"]["description"] =~ "msg:ID references"
    assert specs["search"]["description"] =~ "matched literally as written"
    assert specs["look"]["description"] =~ "supports images and PDFs only"
    assert specs["read_tool_transcript"]["description"] =~ "delegated sub-agent"
    assert get_in(specs, ["elixir_eval", "input_schema", "required"]) == ["code", "description"]
    assert get_in(specs, ["run_shell", "input_schema", "required"]) == ["command", "description"]

    assert get_in(specs, ["run_shell", "input_schema", "properties", "description", "required"]) ==
             [
               "action",
               "goals",
               "assumptions"
             ]
  end

  test "spawn_agent is exposed in tool specs" do
    spec = Enum.find(Tools.specs_for_api(), &(&1["name"] == "spawn_agent"))

    refute is_nil(spec)
    assert get_in(spec, ["input_schema", "required"]) == ["prompt"]
  end

  test "spawn_agent starts an adhoc cycle with default tools, links it to the chat, and tracks it as a task" do
    %{bot_id: bot_id, session_id: session_id} = start_charlie_bot()
    chat_id = unique_chat_id()
    model = FakeLLM.claim()

    assert {:ok, result} =
             Tools.execute(
               "spawn_agent",
               %{
                 "prompt" => "Say hi from the delegated agent",
                 "model" => model
               },
               chat_id,
               bot_id: bot_id,
               bot_username: "charliebuddybot",
               session_id: session_id
             )

    assert result["status"] == "started"
    assert result["task_id"] == "agent:#{result["cycle_id"]}"
    assert result["model"] == model
    assert result["tools"] == ["run_shell", "elixir_eval"]
    assert result["check_tool"] == "read_tool_transcript"
    assert result["open_url"] =~ result["cycle_id"]

    assert result["check_input"] == %{
             "cycle_id" => result["cycle_id"],
             "include_messages" => true
           }

    assert_receive {FakeLLM, from, %Request{} = request}, 5_000

    assert [%LLMMessage{role: :user, content: [%{"type" => "text", "text" => prompt}]}] =
             request.messages

    assert prompt == "Say hi from the delegated agent"
    assert request.model == model

    FakeLLM.reply(
      from,
      {:ok,
       %{
         text: "delegated answer",
         content: [%{"type" => "text", "text" => "delegated answer"}],
         stop_reason: "stop"
       }}
    )

    assert :ok = wait_for_cycle_status(result["cycle_id"], :completed)

    cycle = Repo.get!(Cycle, result["cycle_id"])
    assert cycle.status == :completed
    assert cycle.model == model
    assert Enum.map(cycle.config["tool_specs"], & &1["name"]) == ["run_shell", "elixir_eval"]

    task = Repo.get!(Task, result["task_id"])
    assert task.type == "agent"
    assert task.status == "completed"
    assert task.metadata["cycle_id"] == result["cycle_id"]
    assert task.metadata["final_reply"] == "delegated answer"

    assert Repo.get_by!(CycleLink,
             cycle_id: result["cycle_id"],
             bot_id: bot_id,
             chat_id: chat_id
           )

    assert {:ok, transcript} =
             Tools.execute(
               "read_tool_transcript",
               %{"cycle_id" => result["cycle_id"], "include_messages" => true},
               chat_id,
               bot_id: bot_id,
               session_id: session_id
             )

    assert transcript =~ result["cycle_id"]
    assert transcript =~ "Final reply:"
    assert transcript =~ "delegated answer"
    assert transcript =~ "[#{result["task_id"]}] type=agent"
  end

  test "ask sends an inline-keyboard question and persists a pending ask" do
    test_pid = self()
    chat_id = unique_chat_id()
    cycle_id = Repo.insert!(%Cycle{}).id

    send_message_fun = fn session_id, sent_chat_id, text, opts ->
      send(test_pid, {:ask_sent, session_id, sent_chat_id, text, opts})
      {:ok, %{"id" => 4321}}
    end

    assert {:await, payload} =
             Tools.execute(
               "ask",
               %{"question" => "Pick one", "alternatives" => ["Option A", "Option B"]},
               chat_id,
               session_id: "charlie",
               bot_id: "charlie",
               cycle_id: cycle_id,
               tool_use_id: "toolu_ask_1",
               system_prompt: "Test system prompt",
               model: "claude-opus-4-6",
               tools: Tools.specs_for_api(),
               thinking: %{"budget_tokens" => 128},
               effort: "high",
               reply_to: 555,
               send_message_fun: send_message_fun
             )

    assert payload["kind"] == "ask"
    assert payload["reason"] == "Waiting for the user's answer."
    assert payload["question_message_id"] == 4321

    assert_receive {:ask_sent, "charlie", ^chat_id, "Pick one", opts}, 1_000
    assert opts[:reply_to] == 555
    assert get_in(opts[:reply_markup], ["@type"]) == "replyMarkupInlineKeyboard"
    assert get_in(opts[:reply_markup], ["rows", Access.at(0), Access.at(0), "text"]) == "Option A"
    assert get_in(opts[:reply_markup], ["rows", Access.at(1), Access.at(0), "text"]) == "Option B"

    pending_ask = Repo.get!(PendingAsk, payload["pending_ask_id"])
    assert pending_ask.chat_id == chat_id
    assert pending_ask.message_id == 4321
    assert pending_ask.tool_use_id == "toolu_ask_1"
    assert pending_ask.question == "Pick one"
    assert pending_ask.alternatives == ["Option A", "Option B"]
    assert pending_ask.config["system"] == "Test system prompt"
    assert pending_ask.config["model"] == "claude-opus-4-6"
    assert pending_ask.config["effort"] == "high"
  end

  test "spawn_agent rejects unknown tool names" do
    assert {:error, message} =
             Tools.execute(
               "spawn_agent",
               %{"prompt" => "Delegate this", "tools" => ["shell", "definitely_not_real"]},
               unique_chat_id(),
               bot_id: "charlie",
               bot_username: "charliebuddybot",
               session_id: "charlie"
             )

    assert message =~ "unknown tool names: definitely_not_real"
    assert message =~ "run_shell"
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

  test "run_shell falls back to the current working directory for an empty working_dir" do
    {:ok, result} =
      Tools.execute(
        "run_shell",
        %{"command" => "pwd", "working_dir" => ""},
        unique_chat_id(),
        []
      )

    assert [_, task_id, working_dir] =
             Regex.run(~r/^Shell (.+?): `pwd`\n(.+)$/s, result)

    task = Repo.get!(Task, task_id)

    expected_stat = File.stat!(task.metadata["working_dir"])
    actual_stat = File.stat!(working_dir)

    assert {expected_stat.major_device, expected_stat.minor_device, expected_stat.inode} ==
             {actual_stat.major_device, actual_stat.minor_device, actual_stat.inode}

    assert working_dir != ""
  end

  defp unique_chat_id do
    9_000_000_000 + System.unique_integer([:positive])
  end

  defp wait_for_cycle_status(cycle_id, status, attempts \\ 100)

  defp wait_for_cycle_status(cycle_id, status, attempts)
       when is_binary(cycle_id) and attempts > 0 do
    case Repo.get!(Cycle, cycle_id).status do
      ^status ->
        :ok

      _other ->
        receive do
        after
          10 -> wait_for_cycle_status(cycle_id, status, attempts - 1)
        end
    end
  end

  defp wait_for_cycle_status(cycle_id, status, 0) do
    flunk("cycle #{cycle_id} did not reach status #{inspect(status)} in time")
  end
end
