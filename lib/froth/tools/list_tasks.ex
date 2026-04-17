defmodule Froth.Tools.ListTasks do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block
  alias Froth.Tools.Support

  @impl true
  def name, do: "list_tasks"

  @impl true
  def label, do: "list tasks"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" => "List active and recently completed tasks with output rates and status.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{}, _hooks) do
    tasks = Froth.Tasks.list_recent(Support.bot_id(ctx))

    if tasks == [] do
      {:ok, "No tasks."}
    else
      {:ok,
       Enum.map(tasks, fn task ->
         Block.new(
           [
             kind: "task",
             id: task.task_id,
             label: task.label || task.type,
             status: task.status,
             elapsed: Support.format_task_elapsed(task)
           ],
           nil
         )
       end)}
    end
  end
end
