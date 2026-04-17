defmodule Froth.Tools.Await do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Agent.{AwaitControl, Surface, ToolUse}
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.BotAdapter
  alias Froth.Tools.PendingAskSupport

  @impl true
  def name, do: "await"

  @impl true
  def label, do: "await"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Pause for a human decision about currently tracked background tasks. Use this when you have one or more running shell or eval tasks and need to know whether to keep waiting, keep working in parallel, cancel the tasks, or check their progress. The tool sends a Telegram prompt with explicit buttons and resumes the same cycle with the user's decision, unless they choose to detach or cancel the cycle entirely. Do not use this unless there is real background work in flight; if nothing is running, the tool will just tell you that no tracked tasks were found.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" =>
              "Short explanation of what the background tasks are doing and why the decision matters right now."
          }
        },
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(
        %Context{
          surface: %Surface{session_id: session_id, chat_id: chat_id, reply_to: reply_to},
          bot_config: %BotConfig{id: bot_id},
          cycle_id: cycle_id,
          system_prompt: system_prompt,
          view: %View{active_task_ids: active_task_ids}
        } = ctx,
        %ToolUse{id: tool_use_id, input: input},
        hooks
      )
      when is_binary(session_id) and is_integer(chat_id) and is_binary(bot_id) and
             is_binary(cycle_id) and is_binary(tool_use_id) and is_binary(system_prompt) and
             is_map(input) do
    task_ids = Enum.filter(active_task_ids, &is_binary/1)

    if task_ids == [] do
      {:ok, "No tracked background tasks are currently running."}
    else
      reason =
        case String.trim(to_string(input["reason"] || "")) do
          "" -> "Waiting for background tasks to settle."
          text -> text
        end

      message_text = AwaitControl.render_message(reason, task_ids)
      send_message_fun = Keyword.get(hooks, :send_message_fun, &BotAdapter.send_message/4)

      case send_message_fun.(session_id, chat_id, message_text,
             reply_to: reply_to,
             reply_markup: AwaitControl.reply_markup()
           ) do
        {:ok, sent} ->
          config =
            ctx
            |> PendingAskSupport.session_config()
            |> Map.put("kind", "await")
            |> Map.put("reason", reason)
            |> Map.put("reply_to", reply_to)
            |> Map.put("task_ids", task_ids)

          with {:ok, message_id} <- PendingAskSupport.message_id(sent),
               {:ok, pending_ask} <-
                 PendingAskSupport.create_pending_ask(
                   %{
                     cycle_id: cycle_id,
                     bot_id: bot_id,
                     chat_id: chat_id,
                     message_id: message_id,
                     tool_use_id: tool_use_id,
                     question: message_text,
                     alternatives: AwaitControl.alternatives(),
                     config: config
                   },
                   bot_id,
                   chat_id,
                   message_id
                 ) do
            {:await,
             %{
               "kind" => "await",
               "reason" => reason,
               "pending_ask_id" => pending_ask.id,
               "question_message_id" => pending_ask.message_id,
               "task_ids" => task_ids,
               "message_text" => message_text,
               "sent_message" => sent
             }}
          else
            {:error, reason} -> {:error, PendingAskSupport.format_error(reason)}
          end

        {:error, reason} ->
          {:error, PendingAskSupport.format_error(reason)}
      end
    end
  end

  def execute(_ctx, _tool_call, _hooks), do: {:error, "await requires a full Telegram context"}
end
