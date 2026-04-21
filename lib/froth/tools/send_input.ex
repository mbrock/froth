defmodule Froth.Tools.SendInput do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block

  @impl true
  def name, do: "send_input"

  @impl true
  def label, do: "send input"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Send stdin input to a running shell task. Use for interactive commands that expect input.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Task ID (e.g. shell:a3f8c1)."
          },
          "input" => %{
            "type" => "string",
            "description" =>
              "Text to send to stdin (newline appended automatically)."
          }
        },
        "required" => ["task_id", "input"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{}, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    task_id = input["task_id"]
    text = input["input"] <> "\n"

    if Froth.Tasks.Shell.alive?(task_id) do
      Froth.Tasks.Shell.send_input(task_id, text)
      {:ok, [Block.new([kind: "input_sent", task_id: task_id], nil)]}
    else
      {:error, "Task #{task_id} is not running."}
    end
  end
end
