defmodule Froth.Agent.WorkerTest do
  use Froth.AnthropicCase, async: false

  import Ecto.Query
  alias Froth.Agent
  alias Froth.ObjectStore
  alias Froth.Agent.{Config, Cycle, Message, Worker, ToolUse}
  alias Froth.Event
  alias Froth.LLM.Fake, as: FakeLLM
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.LLM.Request
  alias Froth.Repo

  setup do
    root_dir =
      Path.join(System.tmp_dir!(), "froth-agent-spine-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:froth, ObjectStore, [])

    Application.put_env(:froth, ObjectStore,
      mode: :local,
      root_dir: root_dir,
      public_base: "http://example.test/froth/objects"
    )

    on_exit(fn ->
      Application.put_env(:froth, ObjectStore, previous)
      File.rm_rf(root_dir)
    end)

    :ok
  end

  defmodule TestExecutor do
    use GenServer

    def start_link(fun), do: GenServer.start_link(__MODULE__, fun)

    def execute(fun, tool_use, context), do: fun.(tool_use, context)

    @impl true
    def init(fun), do: {:ok, fun}

    @impl true
    def handle_call({:prepare_tool, tool_use, context}, _from, fun) do
      {:reply, {:ok, %{execute: {__MODULE__, :execute, [fun, tool_use, context]}}}, fun}
    end

    @impl true
    def handle_call({:commit_tool, _tool_use, _context, _prepared, outcome}, _from, fun) do
      result =
        case outcome do
          %{result: result} -> result
          other -> other
        end

      {:reply, result, fun}
    end

    @impl true
    def handle_call({:execute, tool_use, context}, _from, fun) do
      {:reply, fun.(tool_use, context), fun}
    end
  end

  defp echo_tool_spec do
    %{
      "name" => "froth_echo",
      "description" => "Echo text back.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    }
  end

  defp slow_tool_spec do
    %{
      "name" => "slow_tool",
      "description" => "A tool that takes a long time.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }
    }
  end

  defp start_worker(messages, fixture, opts) do
    {provider, model} =
      if fixture do
        notify_pid = Keyword.get(opts, :notify, self())
        replayer = start_supervised!({Froth.SSEReplay, fixture: fixture, notify_pid: notify_pid})
        {:fakeai, Froth.SSEReplay.model(replayer)}
      else
        {Keyword.get(opts, :provider, :anthropic), Keyword.get(opts, :model, "claude-opus-4-6")}
      end

    tools = Keyword.get(opts, :tools, [echo_tool_spec()])
    executor = Keyword.fetch!(opts, :executor)

    config = %Config{
      provider: provider,
      model: model,
      tools: tools,
      tool_executor: executor,
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms)
    }

    cycle = Repo.insert!(%Cycle{})

    Enum.reduce(messages, nil, fn msg, parent_id ->
      saved =
        Repo.insert!(%Message{
          role: msg.role,
          content: msg.content,
          parent_id: parent_id
        })

      Agent.append_event(cycle, %{head_id: saved.id, message_id: saved.id})
      saved.id
    end)

    pid = start_supervised!({Worker, {cycle, config}})
    {pid, cycle}
  end

  defp start_executor(fun) do
    start_supervised!({TestExecutor, fun})
  end

  defp append_cycle_message(%Cycle{} = cycle, parent_id, role, content, seq) do
    message =
      Repo.insert!(%Message{
        role: role,
        content: Message.wrap(content),
        parent_id: parent_id
      })

    Agent.append_event(
      cycle,
      %{kind: "message.appended", head_id: message.id, message_id: message.id},
      seq
    )

    message
  end

  defp wait_for_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5000
    assert reason == :normal
  end

  defp attach_tool_telemetry do
    handler_id = "worker-test-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:froth, :agent, :tool, :started],
          [:froth, :agent, :tool, :completed],
          [:froth, :agent, :tool, :failed],
          [:froth, :agent, :tool, :timed_out]
        ],
        fn event_name, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp cycle_message_events(cycle_id) do
    cycle_id
    |> cycle_events()
    |> Enum.filter(&(event_kind(&1) == "message.appended"))
  end

  defp cycle_messages(cycle_id) do
    cycle_id
    |> cycle_message_events()
    |> Enum.map(fn event ->
      Repo.get!(Message, event_message_id(event) || event_head_id(event))
    end)
  end

  defp cycle_events(cycle_id) do
    Repo.all(
      from(e in Event,
        where:
          like(e.event, "froth.agent.%") and
            fragment("?->>'cycle_id' = ?", e.metadata, ^cycle_id),
        order_by: [asc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)]
      )
    )
  end

  defp latest_cycle_event(cycle_id, kind) do
    Repo.one!(
      from(e in Event,
        where:
          e.event == ^"froth.agent.#{kind}" and
            fragment("?->>'cycle_id' = ?", e.metadata, ^cycle_id),
        order_by: [desc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)],
        limit: 1
      )
    )
  end

  defp event_seq(%Event{metadata: metadata}) when is_map(metadata), do: metadata["seq"]
  defp event_seq(_event), do: nil

  defp event_kind(%Event{metadata: metadata}) when is_map(metadata), do: metadata["kind"]
  defp event_kind(_event), do: nil

  defp event_head_id(%Event{metadata: metadata}) when is_map(metadata), do: metadata["head_id"]
  defp event_head_id(_event), do: nil

  defp event_message_id(%Event{metadata: metadata}) when is_map(metadata),
    do: metadata["message_id"]

  defp event_message_id(_event), do: nil

  test "begin_cycle stores the full message text preview" do
    long_text = String.duplicate("there is no truncation here. ", 20)
    message = Repo.insert!(Message.user(long_text))

    cycle = Agent.begin_cycle(message, %Config{model: "claude-opus-4-6"})
    event = latest_cycle_event(cycle.id, "message.appended")

    assert event.metadata["text_preview"] == long_text
    refute event.metadata["text_preview"] =~ "..."
  end

  test "update_cycle preserves boolean values in nested config maps" do
    message = Repo.insert!(Message.user("hello"))

    config = %Config{
      model: "claude-opus-4-6",
      tools: [
        %{
          "name" => "send_message",
          "description" => "Send a message.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}},
            "required" => ["text"],
            "additionalProperties" => false
          }
        }
      ]
    }

    cycle = Agent.begin_cycle(message, config)

    cycle =
      Agent.update_cycle(cycle, %{
        config: Map.put(cycle.config || %{}, "parent_span_id", "span123")
      })

    fresh = Repo.get!(Cycle, cycle.id)

    assert get_in(fresh.config, [
             "tool_specs",
             Access.at(0),
             "input_schema",
             "additionalProperties"
           ]) ==
             false
  end

  test "latest_head_ids batches current heads from message append events" do
    cycle_one = Repo.insert!(%Cycle{})
    cycle_two = Repo.insert!(%Cycle{})

    first_one = append_cycle_message(cycle_one, nil, :user, "one", 0)
    Agent.append_event(cycle_one, %{kind: "tool.started", head_id: first_one.id}, 1)
    latest_one = append_cycle_message(cycle_one, first_one.id, :agent, "two", 2)
    Agent.append_event(cycle_one, %{kind: "tool.completed", head_id: latest_one.id}, 3)

    first_two = append_cycle_message(cycle_two, nil, :user, "alpha", 0)
    latest_two = append_cycle_message(cycle_two, first_two.id, :agent, "beta", 1)
    Agent.append_event(cycle_two, %{kind: "llm.completed", head_id: latest_two.id}, 2)

    assert Agent.latest_head_id(cycle_one) == latest_one.id
    assert Agent.latest_head_id(cycle_two) == latest_two.id

    assert Agent.latest_head_ids([cycle_two.id, cycle_one.id, cycle_one.id, nil, ""]) == %{
             cycle_one.id => latest_one.id,
             cycle_two.id => latest_two.id
           }
  end

  describe "simple reply (no tools)" do
    test "calls the LLM once and stops" do
      executor = start_executor(fn _, _ -> "ok" end)

      {pid, cycle} =
        start_worker([Message.user("hello")], "simple_reply", tools: [], executor: executor)

      assert_receive {:api_call, 0, _body}, 5000
      assert_receive {:replay_done, 0}, 5000
      wait_for_exit(pid)

      assert Repo.get!(Cycle, cycle.id)
    end

    test "persists messages to the database" do
      executor = start_executor(fn _, _ -> "ok" end)

      {pid, cycle} =
        start_worker([Message.user("hello")], "simple_reply", tools: [], executor: executor)

      wait_for_exit(pid)

      events = cycle_events(cycle.id)
      assert length(events) >= 2

      messages = cycle_messages(cycle.id)
      assert hd(messages).role == :user
      assert List.last(messages).role == :agent
    end

    test "does not crash when request previews truncate unicode text" do
      executor = start_executor(fn _, _ -> "ok" end)
      long_text = String.duplicate("Ben oui — ", 80)

      {pid, _cycle} =
        start_worker([Message.user(long_text)], "simple_reply", tools: [], executor: executor)

      assert_receive {:api_call, 0, _body}, 5000
      assert_receive {:replay_done, 0}, 5000
      wait_for_exit(pid)
    end

    test "records a durable cycle summary and llm execution events" do
      executor = start_executor(fn _, _ -> "ok" end)

      {pid, cycle} =
        start_worker([Message.user("hello")], "simple_reply", tools: [], executor: executor)

      wait_for_exit(pid)

      cycle = Repo.get!(Cycle, cycle.id)

      assert cycle.status == :completed
      assert cycle.provider == "fakeai"
      assert String.starts_with?(cycle.model, "fakeai-slop-")
      assert is_binary(cycle.root_span_id)
      assert %DateTime{} = cycle.started_at
      assert %DateTime{} = cycle.finished_at
      assert is_binary(cycle.system_prompt_hash)
      assert is_binary(cycle.toolset_hash)
      assert String.starts_with?(cycle.config["model"], "fakeai-slop-")
      assert cycle.config["provider"] == "fakeai"

      kinds = Enum.map(cycle_events(cycle.id), &event_kind/1)

      assert "cycle.started" in kinds
      assert "llm.requested" in kinds
      assert "llm.completed" in kinds
      assert "cycle.completed" in kinds
    end

    test "keeps event seq values contiguous across worker-managed events" do
      executor = start_executor(fn _, _ -> "ok" end)

      {pid, cycle} =
        start_worker([Message.user("hello")], "simple_reply", tools: [], executor: executor)

      wait_for_exit(pid)

      events =
        cycle.id
        |> cycle_events()
        |> Enum.reject(&is_nil(event_seq(&1)))

      assert Enum.map(events, &event_seq/1) == Enum.to_list(0..(length(events) - 1))
    end
  end

  describe "tool use cycle" do
    test "executes the tool with correct arguments" do
      test_pid = self()

      executor =
        start_executor(fn tool_use, _context ->
          send(test_pid, {:tool_executed, tool_use})
          "ok"
        end)

      {pid, _cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      assert_receive {:tool_executed,
                      %ToolUse{name: "froth_echo", input: %{"text" => "test message"}}},
                     5000

      wait_for_exit(pid)
    end

    test "sends tool results back to the LLM on the second call" do
      executor =
        start_executor(fn %ToolUse{input: %{"text" => text}}, _context -> "echoed: #{text}" end)

      {pid, _cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      assert_receive {:api_call, 1, body}, 5000

      messages = body["messages"]
      last_message = List.last(messages)
      assert last_message["role"] == "user"

      [tool_result] = last_message["content"]
      assert tool_result["type"] == "tool_result"
      assert tool_result["tool_use_id"] == "toolu_01723uR8LLoYDLV4oqbtHEd4"
      assert tool_result["content"] == "echoed: test message"

      wait_for_exit(pid)
    end

    test "preserves structured tool results on the second call" do
      executor =
        start_executor(fn %ToolUse{input: %{"text" => text}}, _context ->
          [
            %{"type" => "text", "text" => "echoed: #{text}"},
            %{
              type: "image",
              source: %{
                type: "base64",
                media_type: "image/png",
                data: "aGVsbG8="
              }
            }
          ]
        end)

      {pid, _cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      assert_receive {:api_call, 1, body}, 5000

      messages = body["messages"]
      last_message = List.last(messages)
      assert last_message["role"] == "user"

      [tool_result] = last_message["content"]

      assert tool_result == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_01723uR8LLoYDLV4oqbtHEd4",
               "content" => [
                 %{"type" => "text", "text" => "echoed: test message"},
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "image/png",
                     "data" => "aGVsbG8="
                   }
                 }
               ]
             }

      wait_for_exit(pid)
    end

    test "persists all messages including tool results" do
      executor =
        start_executor(fn %ToolUse{input: %{"text" => text}}, _context -> "echoed: #{text}" end)

      {pid, cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      wait_for_exit(pid)

      messages = cycle_messages(cycle.id)
      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :agent, :user, :agent]
    end

    test "sanitizes invalid utf-8 in tool results before persisting them" do
      replacement = <<0xEF, 0xBF, 0xBD>>

      executor =
        start_executor(fn %ToolUse{input: %{"text" => text}}, _context ->
          <<"echoed: ", text::binary, 0xF0>>
        end)

      {pid, cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      assert_receive {:api_call, 1, body}, 5000

      messages = body["messages"]
      last_message = List.last(messages)
      assert last_message["role"] == "user"

      [tool_result] = last_message["content"]

      assert tool_result["content"] == <<"echoed: test message", replacement::binary>>
      assert String.valid?(tool_result["content"])

      wait_for_exit(pid)

      messages = cycle_messages(cycle.id)
      persisted_tool_result = Enum.at(messages, 2)
      [persisted_block] = persisted_tool_result.content

      assert persisted_block["content"] == <<"echoed: test message", replacement::binary>>
      assert String.valid?(persisted_block["content"])

      completed = latest_cycle_event(cycle.id, "tool.completed")
      assert completed.metadata["result"] == <<"echoed: test message", replacement::binary>>
      assert String.valid?(completed.metadata["result"])
    end

    test "continues thinking when tool result text merely contains Yielding:" do
      model = FakeLLM.claim()

      executor =
        start_executor(fn %ToolUse{}, _context ->
          "def normalize_result({:yield, reason}), do: {:ok, \"Yielding: \#{reason}\"}"
        end)

      {pid, cycle} =
        start_worker([Message.user("show transcript")], nil,
          provider: :fakeai,
          model: model,
          executor: executor
        )

      assert_receive {FakeLLM, turn_1, %Request{messages: [%LLMMessage{role: :user}]}}, 5000

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "show transcript"}
             }
           ],
           stop_reason: "tool_use"
         }}
      )

      assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5000

      assert %LLMMessage{role: :user, content: [%{"type" => "tool_result", "content" => content}]} =
               List.last(request_2.messages)

      assert String.contains?(content, "Yielding:")

      FakeLLM.reply(
        turn_2,
        {:ok,
         %{
           text: "done",
           content: [%{"type" => "text", "text" => "done"}],
           stop_reason: "stop"
         }}
      )

      wait_for_exit(pid)

      messages = cycle_messages(cycle.id)
      assert Enum.map(messages, & &1.role) == [:user, :agent, :user, :agent]
    end

    test "continues after provider-managed MCP tools without invoking the local executor" do
      test_pid = self()
      model = FakeLLM.claim()

      executor =
        start_executor(fn tool_use, _context ->
          send(test_pid, {:tool_executed, tool_use})
          "unexpected"
        end)

      {pid, cycle} =
        start_worker([Message.user("what is 2+2?")], nil,
          provider: :fakeai,
          model: model,
          executor: executor
        )

      ref = Process.monitor(pid)

      assert_receive {FakeLLM, turn_1, %Request{messages: [%LLMMessage{role: :user}]}}, 5_000

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "mcp_tool_use",
               "id" => "mcptoolu_1",
               "name" => "compute",
               "server_name" => "wolfram",
               "input" => %{"query" => "2+2"}
             },
             %{
               "type" => "mcp_tool_result",
               "tool_use_id" => "mcptoolu_1",
               "content" => [%{"type" => "text", "text" => "4"}]
             }
           ],
           stop_reason: "pause_turn"
         }}
      )

      assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5_000
      refute_receive {:tool_executed, _tool_use}, 200

      assert %LLMMessage{role: :assistant, content: assistant_blocks} =
               List.last(request_2.messages)

      assert Enum.any?(assistant_blocks, &(&1["type"] == "mcp_tool_use"))
      assert Enum.any?(assistant_blocks, &(&1["type"] == "mcp_tool_result"))

      FakeLLM.reply(
        turn_2,
        {:ok,
         %{
           text: "The answer is 4.",
           content: [%{"type" => "text", "text" => "The answer is 4."}],
           stop_reason: "end_turn"
         }}
      )

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      messages = cycle_messages(cycle.id)
      assert Enum.map(messages, & &1.role) == [:user, :agent, :agent]
      assert Enum.any?(hd(tl(messages)).content, &(&1["type"] == "mcp_tool_use"))

      cycle = Repo.get!(Cycle, cycle.id)
      assert cycle.status == :completed
    end

    test "stops the cycle only on an explicit yield result" do
      model = FakeLLM.claim()

      executor =
        start_executor(fn %ToolUse{}, _context ->
          {:yield, "Waiting for subscribed tasks."}
        end)

      {pid, cycle} =
        start_worker([Message.user("wait")], nil,
          provider: :fakeai,
          model: model,
          executor: executor
        )

      ref = Process.monitor(pid)

      assert_receive {FakeLLM, turn_1, %Request{messages: [%LLMMessage{role: :user}]}}, 5000

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "wait"}
             }
           ],
           stop_reason: "tool_use"
         }}
      )

      refute_receive {FakeLLM, _, _}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000

      messages = cycle_messages(cycle.id)
      assert Enum.map(messages, & &1.role) == [:user, :agent, :user]

      last_message = List.last(messages)
      [tool_result] = last_message.content
      assert tool_result["type"] == "tool_result"
      assert tool_result["content"] == "Yielding: Waiting for subscribed tasks."

      outcome = latest_cycle_event(cycle.id, "control.outcome")

      assert outcome.metadata["outcome"] == "yield"
      assert outcome.metadata["reason"] == "Waiting for subscribed tasks."
    end

    test "awaits hidden tool results without persisting a fake tool_result message" do
      model = FakeLLM.claim()

      executor =
        start_executor(fn %ToolUse{}, _context ->
          {:await, %{"reason" => "Waiting for the user's answer.", "kind" => "ask"}}
        end)

      {pid, cycle} =
        start_worker([Message.user("question")], nil,
          provider: :fakeai,
          model: model,
          executor: executor
        )

      ref = Process.monitor(pid)

      assert_receive {FakeLLM, turn_1, %Request{messages: [%LLMMessage{role: :user}]}}, 5_000

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "tool_use",
               "id" => "call_ask_1",
               "name" => "froth_echo",
               "input" => %{"text" => "question"}
             }
           ],
           stop_reason: "tool_use"
         }}
      )

      refute_receive {FakeLLM, _, _}, 200

      state = :sys.get_state(pid)
      assert match?({:awaiting_user_input, _}, state.phase)
      assert state.cycle.status == :awaiting_user_input

      messages = cycle_messages(cycle.id)
      assert Enum.map(messages, & &1.role) == [:user, :agent]

      outcome = latest_cycle_event(cycle.id, "control.outcome")
      assert outcome.metadata["outcome"] == "await_user_input"
      assert outcome.metadata["reason"] == "Waiting for the user's answer."

      Process.exit(pid, {:shutdown, :cancelled})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :cancelled}}, 5_000
    end

    test "times out stalled tools using the worker-owned deadline" do
      attach_tool_telemetry()

      executor =
        start_executor(fn %ToolUse{}, _context ->
          Process.sleep(50)
          "too late"
        end)

      {pid, _cycle} =
        start_worker(
          [Message.user("echo test message")],
          "tool_use_echo",
          executor: executor,
          tool_timeout_ms: 10
        )

      assert_receive {:api_call, 1, body}, 5000

      messages = body["messages"]
      last_message = List.last(messages)
      [tool_result] = last_message["content"]

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :started], %{},
                      %{tool_name: "froth_echo", tool_use_id: "toolu_01723uR8LLoYDLV4oqbtHEd4"}},
                     5000

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :timed_out], measurements,
                      %{
                        timeout_ms: 10,
                        tool_name: "froth_echo",
                        tool_use_id: "toolu_01723uR8LLoYDLV4oqbtHEd4"
                      }},
                     5000

      assert is_integer(measurements.duration)
      assert measurements.duration > 0

      assert tool_result == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_01723uR8LLoYDLV4oqbtHEd4",
               "content" => "tool timed out after 10ms",
               "is_error" => true
             }

      wait_for_exit(pid)
    end

    test "uses tool-specific timeout overrides when no cycle timeout is configured" do
      attach_tool_telemetry()
      model = FakeLLM.claim()
      previous_overrides = Application.get_env(:froth, :tool_timeout_overrides)

      on_exit(fn ->
        if previous_overrides do
          Application.put_env(:froth, :tool_timeout_overrides, previous_overrides)
        else
          Application.delete_env(:froth, :tool_timeout_overrides)
        end
      end)

      Application.put_env(:froth, :tool_timeout_overrides, %{"slow_tool" => 10})

      executor =
        start_executor(fn %ToolUse{}, _context ->
          Process.sleep(50)
          "too late"
        end)

      {pid, _cycle} =
        start_worker(
          [Message.user("run the slow tool")],
          nil,
          provider: :fakeai,
          model: model,
          executor: executor,
          tools: [slow_tool_spec()]
        )

      assert_receive {FakeLLM, turn_1, %Request{}}, 5000

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "slow_tool",
               "input" => %{"query" => "what is slow"}
             }
           ],
           stop_reason: "tool_use"
         }}
      )

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :timed_out], measurements,
                      %{
                        timeout_ms: 10,
                        tool_name: "slow_tool",
                        tool_use_id: "call_1"
                      }},
                     5000

      assert is_integer(measurements.duration)
      assert measurements.duration > 0

      assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5000

      assert %LLMMessage{role: :user, content: [tool_result]} = List.last(request_2.messages)

      assert tool_result == %{
               "type" => "tool_result",
               "tool_use_id" => "call_1",
               "content" => "tool timed out after 10ms",
               "is_error" => true
             }

      FakeLLM.reply(
        turn_2,
        {:ok,
         %{
           text: "done",
           content: [%{"type" => "text", "text" => "done"}],
           stop_reason: "stop"
         }}
      )

      wait_for_exit(pid)
    end

    test "emits completed tool telemetry with duration and metadata" do
      attach_tool_telemetry()

      executor =
        start_executor(fn %ToolUse{input: %{"text" => text}}, _context -> "echoed: #{text}" end)

      {pid, _cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :started], %{},
                      %{
                        cycle_id: cycle_id,
                        tool_name: "froth_echo",
                        tool_use_id: "toolu_01723uR8LLoYDLV4oqbtHEd4",
                        input_keys: ["text"]
                      }},
                     5000

      assert is_binary(cycle_id)

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :completed], measurements,
                      %{
                        cycle_id: ^cycle_id,
                        result_type: "text",
                        tool_name: "froth_echo",
                        tool_use_id: "toolu_01723uR8LLoYDLV4oqbtHEd4"
                      }},
                     5000

      assert is_integer(measurements.duration)
      assert measurements.duration > 0

      wait_for_exit(pid)
    end

    test "emits failed tool telemetry when a tool returns an error result" do
      attach_tool_telemetry()

      executor =
        start_executor(fn %ToolUse{}, _context ->
          {:error, "echo failed"}
        end)

      {pid, _cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :started], %{},
                      %{tool_name: "froth_echo", tool_use_id: "toolu_01723uR8LLoYDLV4oqbtHEd4"}},
                     5000

      assert_receive {:telemetry_event, [:froth, :agent, :tool, :failed], measurements,
                      %{
                        error: "echo failed",
                        tool_name: "froth_echo",
                        tool_use_id: "toolu_01723uR8LLoYDLV4oqbtHEd4"
                      }},
                     5000

      assert is_integer(measurements.duration)
      assert measurements.duration > 0

      wait_for_exit(pid)
    end

    test "runs prepared tool executions in parallel outside the executor GenServer" do
      test_pid = self()
      model = FakeLLM.claim()

      executor =
        start_executor(fn %ToolUse{id: id, input: %{"text" => text}}, _context ->
          send(test_pid, {:tool_started, id, self(), text})

          receive do
            {:release, ^id} -> "echoed: #{text}"
          end
        end)

      {pid, _cycle} =
        start_worker([Message.user("run both")], nil,
          provider: :fakeai,
          model: model,
          executor: executor
        )

      assert_receive {FakeLLM, turn_1, %Request{messages: [%LLMMessage{role: :user}]}}, 5000

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "first"}
             },
             %{
               "type" => "tool_use",
               "id" => "call_2",
               "name" => "froth_echo",
               "input" => %{"text" => "second"}
             }
           ],
           stop_reason: "tool_use"
         }}
      )

      started =
        for _ <- 1..2 do
          assert_receive {:tool_started, id, task_pid, _text}, 5000
          {id, task_pid}
        end

      assert Enum.sort(Enum.map(started, &elem(&1, 0))) == ["call_1", "call_2"]

      Enum.each(started, fn {id, task_pid} ->
        send(task_pid, {:release, id})
      end)

      assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5000

      assert %LLMMessage{role: :user, content: content} = List.last(request_2.messages)

      assert content
             |> Enum.filter(&(&1["type"] == "tool_result"))
             |> Enum.map(& &1["tool_use_id"])
             |> Enum.sort() == ["call_1", "call_2"]

      FakeLLM.reply(
        turn_2,
        {:ok,
         %{
           text: "done",
           content: [%{"type" => "text", "text" => "done"}],
           stop_reason: "stop"
         }}
      )

      wait_for_exit(pid)
    end

    test "stores large tool payloads out of line on execution events" do
      executor =
        start_executor(fn %ToolUse{}, _context ->
          [
            %{"type" => "text", "text" => "echoed"},
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => String.duplicate("aGVsbG8=", 128)
              }
            }
          ]
        end)

      {pid, cycle} =
        start_worker([Message.user("echo test message")], "tool_use_echo", executor: executor)

      wait_for_exit(pid)

      event = latest_cycle_event(cycle.id, "tool.completed")

      assert is_binary(event.metadata["blob_ref"])
      assert {:ok, path} = ObjectStore.local_path(event.metadata["blob_ref"])
      assert File.exists?(path)
      assert event.metadata["result_type"] == "blocks"
    end
  end

  describe "Agent.run/2" do
    test "returns a cycle and streams events" do
      executor = start_executor(fn _, _ -> "ok" end)
      replayer = start_supervised!({Froth.SSEReplay, fixture: "simple_reply", notify_pid: self()})

      config = %Config{
        provider: :fakeai,
        model: Froth.SSEReplay.model(replayer),
        tools: [],
        tool_executor: executor
      }

      message = Repo.insert!(%Message{role: :user, content: Message.wrap("hello")})

      {cycle, stream} = Froth.Agent.run(message, config)
      assert %Cycle{} = cycle

      all = Enum.to_list(stream)
      events = Enum.filter(all, &match?({:event, _, _}, &1))
      assert length(events) >= 1

      {:event, last_event, last_msg} = List.last(events)
      assert %Event{} = last_event
      assert last_msg.role == :agent
    end

    test "streams tool use cycle events in order" do
      executor =
        start_executor(fn %ToolUse{input: %{"text" => text}}, _context -> "echoed: #{text}" end)

      replayer =
        start_supervised!({Froth.SSEReplay, fixture: "tool_use_echo", notify_pid: self()})

      config = %Config{
        provider: :fakeai,
        model: Froth.SSEReplay.model(replayer),
        tools: [echo_tool_spec()],
        tool_executor: executor
      }

      message = Repo.insert!(%Message{role: :user, content: Message.wrap("echo test message")})

      {_cycle, stream} = Froth.Agent.run(message, config)

      all = Enum.to_list(stream)
      events = Enum.filter(all, &match?({:event, _, _}, &1))
      roles = Enum.map(events, fn {:event, _event, msg} -> msg.role end)
      assert roles == [:agent, :user, :agent]
    end

    test "routes provider selection through Froth.LLM" do
      model = FakeLLM.claim()
      executor = start_executor(fn _, _ -> "ok" end)

      config = %Config{
        provider: :fakeai,
        model: model,
        tools: [],
        tool_executor: executor
      }

      message = Repo.insert!(%Message{role: :user, content: Message.wrap("hello")})

      {_cycle, stream} = Froth.Agent.run(message, config)
      collector = Task.async(fn -> Enum.to_list(stream) end)

      assert_receive {FakeLLM, turn, %Request{model: ^model} = request}, 5_000

      assert [%LLMMessage{role: :user, content: [%{"type" => "text", "text" => "hello"}]}] =
               request.messages

      FakeLLM.reply(
        turn,
        {:ok,
         %{
           text: "hello",
           content: [%{"type" => "text", "text" => "hello"}],
           stop_reason: "stop"
         }}
      )

      all = Task.await(collector, 10_000)

      events = Enum.filter(all, &match?({:event, _, _}, &1))
      {:event, _event, last_msg} = List.last(events)
      assert last_msg.role == :agent
    end
  end

  describe "CycleRuntime.run_to_completion/1" do
    test "threads previous_response_id across tool-result turns in a stateful cycle" do
      model = FakeLLM.claim()

      run_shell_spec =
        Enum.find(Froth.Inference.Tools.specs_for_api(), &(&1["name"] == "run_shell"))

      config = %Config{
        provider: :fakeai,
        model: model,
        system: "You are a helpful assistant.",
        tools: [run_shell_spec],
        tool_executor: nil,
        context: %{},
        effort: "high"
      }

      prompt = "run a quick shell command and summarize it"
      user_message = Repo.insert!(%Message{role: :user, content: Message.wrap(prompt)})
      cycle = Agent.begin_cycle(user_message, config)

      run_task =
        Task.async(fn ->
          Froth.Agent.CycleRuntime.run_to_completion(
            cycle_id: cycle.id,
            cycle: cycle,
            worker_config: config
          )
        end)

      # Turn 1: no previous response id yet.
      assert_receive {FakeLLM, turn_1, %Request{} = request_1}, 5_000
      assert [%LLMMessage{role: :user}] = request_1.messages
      assert request_1.model == model
      assert request_1.provider_options["reasoning_effort"] == "high"
      assert request_1.provider_options["previous_response_id"] == nil

      FakeLLM.reply(
        turn_1,
        {:ok,
         %{
           content: [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "run_shell",
               "input" => %{
                 "command" => "printf 'froth-adhoc\\n'",
                 "description" => %{
                   "action" => "Inspecting the shell output before replying.",
                   "goals" => [
                     "read the command output",
                     "decide whether the command succeeded",
                     "avoid replying from a guess"
                   ],
                   "assumptions" => ["the shell command can run in this workspace"]
                 }
               }
             }
           ],
           stop_reason: "tool_use",
           message_id: "resp_adhoc_tool_1",
           response_id: "resp_adhoc_tool_1"
         }}
      )

      # Turn 2: the cycle should carry the response_id forward.
      assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5_000
      assert request_2.provider_options["previous_response_id"] == "resp_adhoc_tool_1"
      assert length(request_2.messages) == 1

      assert %LLMMessage{
               role: :user,
               content: [
                 %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => content}
               ]
             } = List.last(request_2.messages)

      assert content =~ "froth-adhoc"

      FakeLLM.reply(
        turn_2,
        {:ok,
         %{
           text: "shell finished",
           content: [%{"type" => "text", "text" => "shell finished"}],
           stop_reason: "stop",
           message_id: "resp_adhoc_tool_2",
           response_id: "resp_adhoc_tool_2"
         }}
      )

      {completed_cycle, output} = Task.await(run_task, 10_000)

      assert output == "shell finished"

      completed_cycle = Repo.get!(Cycle, completed_cycle.id)
      assert completed_cycle.status == :completed
      assert completed_cycle.provider == "fakeai"

      messages = cycle_messages(completed_cycle.id)
      assert Enum.map(messages, & &1.role) == [:user, :agent, :user, :agent]
      assert Enum.at(messages, 1).metadata["response_id"] == "resp_adhoc_tool_1"
    end
  end
end
