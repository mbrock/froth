defmodule Froth.Agent.CycleRuntimeTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.CycleRuntime

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

  defp unique_cycle_id do
    "cycle_runtime_test_#{System.unique_integer([:positive, :monotonic])}"
  end
end
