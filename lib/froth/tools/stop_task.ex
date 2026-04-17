defmodule Froth.Tools.StopTask do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block

  @impl true
  def name, do: "stop_task"

  @impl true
  def label, do: "stop task"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" => "Stop a running task. Sends SIGTERM by default, or a specific signal.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task ID (e.g. shell:a3f8c1)."},
          "signal" => %{
            "type" => "string",
            "description" => "Signal to send (e.g. TERM, KILL, INT). Default: TERM."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{}, %ToolUse{input: input}, _hooks) when is_map(input) do
    task_id = input["task_id"]
    signal = input["signal"] || "TERM"

    if Froth.Tasks.Shell.alive?(task_id) do
      Froth.Tasks.Shell.send_signal(task_id, signal)

      {:ok,
       [
         Block.new(
           [kind: "signal_sent", task_id: task_id, signal: signal],
           nil
         )
       ]}
    else
      cond do
        Froth.Tasks.Eval.alive?(task_id) ->
          Froth.Tasks.Eval.stop_eval(task_id)
          Froth.Tasks.stop(task_id)
          {:ok, [Block.new([kind: "task_stopped", task_id: task_id], nil)]}

        true ->
          task = Froth.Tasks.get(task_id)

          if task && task.status in ["pending", "running"] do
            Froth.Tasks.stop(task_id)
            {:ok, [Block.new([kind: "task_stopped", task_id: task_id], nil)]}
          else
            {:error, "Task #{task_id} is not running."}
          end
      end
    end
  end
end
