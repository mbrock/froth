defmodule Froth.Tools.TaskOutput do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block

  @impl true
  def name, do: "task_output"

  @impl true
  def label, do: "task output"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Read recent output lines from a task. Useful for checking progress on long-running commands.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Task ID (e.g. shell:a3f8c1)."
          },
          "lines" => %{
            "type" => "integer",
            "description" =>
              "Number of recent output lines to return. Default 50."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{}, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    task_id = input["task_id"]
    limit = input["lines"] || 50
    events = Froth.Tasks.recent_output(task_id, limit)

    if events == [] do
      {:ok, "No output for task #{task_id}."}
    else
      stats = Froth.Tasks.output_stats(task_id)
      output = Enum.map_join(events, "", & &1.content)

      {:ok,
       [
         Block.new(
           [
             kind: "task_output",
             task_id: task_id,
             total: stats.total,
             rate_per_second: Float.round(stats.rate_per_second, 1)
           ],
           output
         )
       ]}
    end
  end
end
