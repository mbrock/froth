defmodule Froth.Tools.SubscribeTask do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block
  alias Froth.Tools.Support

  @impl true
  def name, do: "subscribe_task"

  @impl true
  def label, do: "subscribe"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Register interest in a task. The system will automatically send you a message when the task completes (or after expect_minutes if still running). After subscribing, you do NOT need to poll, check, or wait — just stop and move on. You will be woken up with the result when it's ready.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Task ID to subscribe to."},
          "expect_minutes" => %{
            "type" => "integer",
            "description" =>
              "Expected completion time in minutes. If still running after this, you'll be notified."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks) when is_map(input) do
    task_id = input["task_id"]
    expect_minutes = input["expect_minutes"]
    task = Froth.Tasks.get(task_id)

    cond do
      task == nil ->
        {:error, "Task #{task_id} not found."}

      task.status in ["completed", "failed", "stopped"] ->
        {:ok, "Task #{task_id} already #{task.status}. No need to subscribe."}

      true ->
        Froth.Tasks.subscribe_telegram(task_id, Support.bot_id(ctx), Support.chat_id(ctx),
          expect_minutes: expect_minutes,
          message_id: Support.reply_to(ctx)
        )

        {:ok,
         [
           Block.new(
             [kind: "subscribed", task_id: task_id, expect_minutes: expect_minutes],
             nil
           )
         ]}
    end
  end
end
