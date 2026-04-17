defmodule Froth.Agent.CycleRuntimeTest do
  use ExUnit.Case, async: false

  alias Froth.Agent.CycleRuntime
  alias Froth.Agent.Cycle
  alias Froth.Agent.ToolUse
  alias Froth.Telegram.Bot.Config, as: BotConfig

  describe "scaffolding: registry + supervisor wiring" do
    test "start_root/1 starts a runtime under CycleSupervisor and registers it" do
      cycle_id = unique_cycle_id()

      {:ok, pid} = CycleRuntime.start_root(cycle_id: cycle_id, bot_id: "charlie")

      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(Froth.Agent.CycleSupervisor, pid)
        end
      end)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert CycleRuntime.whereis(cycle_id) == pid
      assert CycleRuntime.alive?(cycle_id)

      assert %{cycle_id: ^cycle_id, bot_id: "charlie", parent_cycle_id: nil} =
               GenServer.call(CycleRuntime.via(cycle_id), :get_state)
    end

    test "terminating the runtime removes it from the registry" do
      cycle_id = unique_cycle_id()
      {:ok, pid} = CycleRuntime.start_root(cycle_id: cycle_id)

      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(Froth.Agent.CycleSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      # Registry monitors registered pids in its PID-partition process; the
      # runtime's DOWN may reach us before the Registry has processed its
      # own DOWN and unregistered. Force the partition to a sync point so
      # the cleanup is observable.
      _ = :sys.get_state(Module.concat(Froth.Agent.CycleRegistry, "PIDPartition0"))

      refute CycleRuntime.alive?(cycle_id)
      assert CycleRuntime.whereis(cycle_id) == nil
    end

    test "whereis/1 returns nil for unknown cycle ids" do
      assert CycleRuntime.whereis("cycle_does_not_exist_#{System.unique_integer([:positive])}") ==
               nil
    end
  end

  describe "commit_tool: narration and last-sent tracking" do
    test "tracks narration message state" do
      runtime = start_scaffold_runtime()

      tool_use = %ToolUse{id: "call_1", name: "run_shell", input: %{"command" => "pwd"}}
      context = %{cycle_id: "cycle_1", chat_id: 123, reply_to: 456}

      assert {:ok, "ok"} =
               GenServer.call(
                 runtime,
                 {:commit_tool, tool_use, context, %{execution: %{cycle_id: "cycle_1"}},
                  %{
                    result: {:ok, "ok"},
                    narration_message: %{message_id: 77, text: "Checking X", mode: :italic}
                  }}
               )

      state = :sys.get_state(runtime)
      assert state.narration == %{message_id: 77, text: "Checking X", mode: :italic}
    end

    test "clears active narration when a normal message is sent" do
      runtime = start_scaffold_runtime()

      :sys.replace_state(runtime, fn rstate ->
        %{
          rstate
          | narration: %{message_id: 77, text: "Checking X\nAlso checking Y", mode: :italic}
        }
      end)

      tool_use = %ToolUse{id: "call_1", name: "send_message", input: %{"text" => "hello"}}
      context = %{cycle_id: "cycle_1", chat_id: 123, reply_to: 456}

      outcome = %{
        result: {:ok, "sent"},
        sent_message: %{sent: %{"id" => 42}, text: "hello"}
      }

      assert {:ok, "sent"} =
               GenServer.call(
                 runtime,
                 {:commit_tool, tool_use, context, %{execution: %{cycle_id: "cycle_1"}}, outcome}
               )

      state = :sys.get_state(runtime)
      assert state.last_sent == %{id: 42, text: "hello"}
      assert state.narration == nil
    end
  end

  describe "spawn_subagent" do
    test "starts a child runtime under the parent and registers it" do
      parent = start_scaffold_runtime()
      parent_state = :sys.get_state(parent)

      child_cycle_id = unique_cycle_id()

      {:ok, child_pid} =
        CycleRuntime.spawn_subagent(parent, cycle_id: child_cycle_id)

      assert is_pid(child_pid)
      assert CycleRuntime.whereis(child_cycle_id) == child_pid

      child_state = GenServer.call(child_pid, :get_state)
      assert child_state.parent_cycle_id == parent_state.cycle_id
      assert child_state.bot_id == parent_state.bot_id
      assert child_state.bot_config == parent_state.bot_config
      assert child_state.chat_id == parent_state.chat_id
      assert child_state.reply_to == parent_state.reply_to
    end

    test "terminating the parent cascades to children" do
      parent = start_scaffold_runtime()
      child_cycle_id = unique_cycle_id()
      {:ok, child_pid} = CycleRuntime.spawn_subagent(parent, cycle_id: child_cycle_id)

      parent_ref = Process.monitor(parent)
      child_ref = Process.monitor(child_pid)

      :ok = DynamicSupervisor.terminate_child(Froth.Agent.CycleSupervisor, parent)

      assert_receive {:DOWN, ^parent_ref, :process, ^parent, _}, 500
      assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _}, 500
    end
  end

  describe "sync_sent_message_id" do
    test "swaps temporary message ids on narration and last_sent" do
      runtime = start_scaffold_runtime()

      :sys.replace_state(runtime, fn rstate ->
        %{
          rstate
          | last_sent: %{id: 101, text: "hello"},
            narration: %{message_id: 202, text: "Checking X", mode: :italic}
        }
      end)

      :ok = CycleRuntime.sync_sent_message_id(202, 303)
      # Force the cast to be processed before we read state.
      _ = :sys.get_state(runtime)

      state = :sys.get_state(runtime)
      assert state.narration.message_id == 303
      assert state.last_sent.id == 101

      :ok = CycleRuntime.sync_sent_message_id(101, 404)
      _ = :sys.get_state(runtime)

      state = :sys.get_state(runtime)
      assert state.last_sent.id == 404
      assert state.narration.message_id == 303
    end
  end

  defp start_scaffold_runtime do
    cycle_id = unique_cycle_id()

    {:ok, pid} =
      CycleRuntime.start_root(
        cycle_id: cycle_id,
        bot_id: "charlie",
        cycle: %Cycle{id: cycle_id},
        bot_config: minimal_bot_config(),
        chat_id: 123,
        reply_to: 456
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Froth.Agent.CycleSupervisor, pid)
      end
    end)

    pid
  end

  defp minimal_bot_config do
    BotConfig.build(
      id: "charlie",
      session_id: "charlie",
      bot_username: "charliebuddybot",
      bot_user_id: 1,
      owner_user_id: 1,
      model: "claude-opus-4-6",
      system_prompt: "You are Charlie.",
      tools_module: Froth.Telegram.Toolsets.Charlie
    )
  end

  defp unique_cycle_id do
    "cycle_runtime_test_#{System.unique_integer([:positive, :monotonic])}"
  end
end
