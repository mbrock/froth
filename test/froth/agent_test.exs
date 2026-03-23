defmodule Froth.Agent.WorkerTest do
  use Froth.AnthropicCase, async: false

  import Ecto.Query
  alias Froth.Agent.{Config, Cycle, Event, Message, Worker, ToolUse}
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.Repo

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

  defp start_worker(messages, fixture, opts) do
    notify_pid = Keyword.get(opts, :notify, self())

    Application.put_env(
      :froth,
      :sse_stream_fun,
      Froth.SSEReplay.recording_stream_fun(fixture, notify_pid)
    )

    tools = Keyword.get(opts, :tools, [echo_tool_spec()])
    executor = Keyword.fetch!(opts, :executor)

    config = %Config{
      model: "claude-opus-4-6",
      tools: tools,
      tool_executor: executor,
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms)
    }

    cycle = Repo.insert!(%Cycle{})

    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {msg, seq}, parent_id ->
      saved =
        Repo.insert!(%Message{
          role: msg.role,
          content: msg.content,
          parent_id: parent_id
        })

      Repo.insert!(%Event{cycle_id: cycle.id, head_id: saved.id, seq: seq})
      saved.id
    end)

    pid = start_supervised!({Worker, {cycle, config}})
    {pid, cycle}
  end

  defp start_executor(fun) do
    start_supervised!({TestExecutor, fun})
  end

  defp wait_for_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5000
    assert reason == :normal
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

      events = Repo.all(from(e in Event, where: e.cycle_id == ^cycle.id, order_by: e.seq))
      assert length(events) >= 2

      messages = Enum.map(events, fn e -> Repo.get!(Message, e.head_id) end)
      assert hd(messages).role == :user
      assert List.last(messages).role == :agent
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

      events = Repo.all(from(e in Event, where: e.cycle_id == ^cycle.id, order_by: e.seq))
      assert length(events) >= 4

      messages = Enum.map(events, fn e -> Repo.get!(Message, e.head_id) end)
      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :agent, :user, :agent]
    end

    test "times out stalled tools using the worker-owned deadline" do
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

      assert tool_result == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_01723uR8LLoYDLV4oqbtHEd4",
               "content" => "tool timed out after 10ms",
               "is_error" => true
             }

      wait_for_exit(pid)
    end

    test "runs prepared tool executions in parallel outside the executor GenServer" do
      test_pid = self()
      counter = start_supervised!({Elixir.Agent, fn -> 0 end})

      Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
        call =
          Elixir.Agent.get_and_update(counter, fn current ->
            {current, current + 1}
          end)

        send(test_pid, {:llm_call, call, api_messages})

        case call do
          0 ->
            {:ok,
             %{
               text: "",
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
               stop_reason: "tool_use",
               usage: %{},
               model: opts[:model],
               message_id: "msg_1"
             }}

          1 ->
            {:ok,
             %{
               text: "done",
               content: [%{"type" => "text", "text" => "done"}],
               stop_reason: "stop",
               usage: %{},
               model: opts[:model],
               message_id: "msg_2"
             }}
        end
      end)

      executor =
        start_executor(fn %ToolUse{id: id, input: %{"text" => text}}, _context ->
          send(test_pid, {:tool_started, id, self(), text})

          receive do
            {:release, ^id} -> "echoed: #{text}"
          end
        end)

      {pid, _cycle} =
        start_worker([Message.user("run both")], "simple_reply", executor: executor)

      assert_receive {:llm_call, 0, [%LLMMessage{role: :user}]}, 5000

      started =
        for _ <- 1..2 do
          assert_receive {:tool_started, id, task_pid, _text}, 5000
          {id, task_pid}
        end

      assert Enum.sort(Enum.map(started, &elem(&1, 0))) == ["call_1", "call_2"]

      Enum.each(started, fn {id, task_pid} ->
        send(task_pid, {:release, id})
      end)

      assert_receive {:llm_call, 1, api_messages}, 5000

      assert %LLMMessage{role: :user, content: content} = List.last(api_messages)

      assert content
             |> Enum.filter(&(&1["type"] == "tool_result"))
             |> Enum.map(& &1["tool_use_id"])
             |> Enum.sort() == ["call_1", "call_2"]

      wait_for_exit(pid)
    end
  end

  describe "Agent.run/2" do
    test "returns a cycle and streams events" do
      executor = start_executor(fn _, _ -> "ok" end)

      Application.put_env(
        :froth,
        :sse_stream_fun,
        Froth.SSEReplay.recording_stream_fun("simple_reply", self())
      )

      config = %Config{model: "claude-opus-4-6", tools: [], tool_executor: executor}
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

      Application.put_env(
        :froth,
        :sse_stream_fun,
        Froth.SSEReplay.recording_stream_fun("tool_use_echo", self())
      )

      config = %Config{
        model: "claude-opus-4-6",
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
      test_pid = self()
      executor = start_executor(fn _, _ -> "ok" end)

      Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, on_event, opts ->
        send(test_pid, {:llm_call, api_messages, opts})
        on_event.({:text_delta, "hello"})

        {:ok,
         %{
           text: "hello",
           content: [%{"type" => "text", "text" => "hello"}],
           stop_reason: "stop",
           usage: %{},
           model: opts[:model],
           message_id: "msg_test"
         }}
      end)

      config = %Config{
        provider: :openai,
        model: "gpt-5-mini",
        tools: [],
        tool_executor: executor
      }

      message = Repo.insert!(%Message{role: :user, content: Message.wrap("hello")})

      {_cycle, stream} = Froth.Agent.run(message, config)
      all = Enum.to_list(stream)

      assert_receive {:llm_call, api_messages, opts}

      assert [%LLMMessage{role: :user, content: [%{"type" => "text", "text" => "hello"}]}] =
               api_messages

      assert opts[:provider] == :openai
      assert opts[:model] == "gpt-5-mini"

      events = Enum.filter(all, &match?({:event, _, _}, &1))
      {:event, _event, last_msg} = List.last(events)
      assert last_msg.role == :agent
    end
  end
end
