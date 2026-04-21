defmodule Froth.Agent.AwaitControl do
  @moduledoc false

  alias Froth.Tasks
  alias Froth.Telegram.{BotAdapter, PendingAsk}

  @detach_answer "__await_detach__"
  @continue_answer "__await_continue__"
  @cancel_answer "__await_cancel__"
  @check_answer "__await_check__"

  @buttons [
    {@detach_answer, "⛓️‍💥"},
    {@continue_answer, "🏃‍➡️"},
    {@cancel_answer, "⏹️"},
    {@check_answer, "🧐"}
  ]

  def detach_answer, do: @detach_answer
  def continue_answer, do: @continue_answer
  def cancel_answer, do: @cancel_answer
  def check_answer, do: @check_answer

  def await?(%PendingAsk{config: config}) when is_map(config),
    do: config["kind"] == "await"

  def await?(_pending_ask), do: false

  def accepts_message_answer?(%PendingAsk{} = pending_ask),
    do: not await?(pending_ask)

  def accepts_message_answer?(_pending_ask), do: true

  def alternatives do
    Enum.map(@buttons, fn {answer, _icon} -> answer end)
  end

  def reply_markup do
    rows =
      Enum.with_index(@buttons)
      |> Enum.map(fn {{_answer, icon}, index} ->
        %{
          "@type" => "inlineKeyboardButton",
          "text" => icon,
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeCallback",
            "data" => Base.encode64("ask:#{index}")
          }
        }
      end)

    %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => [rows]
    }
  end

  def render_message(reason, task_ids)
      when is_binary(reason) and is_list(task_ids) do
    task_block =
      task_ids
      |> Enum.map(&task_line/1)
      |> Enum.join("\n")
      |> case do
        "" -> "none"
        lines -> lines
      end

    [
      "Awaiting background work",
      nil,
      "Waiting for",
      reason,
      nil,
      "Tasks",
      task_block
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def tool_resolution(%PendingAsk{} = pending_ask) do
    case pending_ask.answer do
      @detach_answer ->
        {:stop_cycle, :detach}

      @cancel_answer ->
        {:stop_cycle, :cancel}

      @check_answer ->
        {:tool_result, check_message(pending_ask)}

      _ ->
        {:tool_result, continue_message(pending_ask)}
    end
  end

  def maybe_finalize_message(%PendingAsk{} = pending_ask, session_id)
      when is_binary(session_id) do
    if await?(pending_ask) and is_integer(pending_ask.message_id) do
      updated_text =
        pending_ask.question <> "\n\n" <> decision_line(pending_ask)

      BotAdapter.edit_message_text(
        session_id,
        pending_ask.chat_id,
        pending_ask.message_id,
        updated_text,
        reply_markup: %{"@type" => "replyMarkupInlineKeyboard", "rows" => []}
      )
    else
      :ok
    end
  end

  def maybe_finalize_message(_pending_ask, _session_id), do: :ok

  def task_ids(%PendingAsk{} = pending_ask) do
    case get_in(pending_ask.config, ["task_ids"]) do
      task_ids when is_list(task_ids) -> Enum.filter(task_ids, &is_binary/1)
      _ -> []
    end
  end

  def reply_to(%PendingAsk{} = pending_ask) do
    case get_in(pending_ask.config, ["reply_to"]) do
      reply_to when is_integer(reply_to) and reply_to > 0 -> reply_to
      _ -> nil
    end
  end

  defp continue_message(%PendingAsk{} = pending_ask) do
    [
      "The user asked you to keep working while the background tasks continue.",
      nil,
      task_status_block(task_ids(pending_ask), include_output?: false)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp check_message(%PendingAsk{} = pending_ask) do
    [
      "The user asked you to check on the background tasks.",
      nil,
      task_status_block(task_ids(pending_ask), include_output?: true)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp task_status_block([], _opts),
    do: "No tracked background tasks were found."

  defp task_status_block(task_ids, opts)
       when is_list(task_ids) and is_list(opts) do
    include_output? = Keyword.get(opts, :include_output?, false)

    Enum.map_join(task_ids, "\n\n", fn task_id ->
      lines = [task_line(task_id)]

      if include_output? do
        case String.trim(Tasks.recent_output_text(task_id, 8)) do
          "" -> Enum.join(lines, "\n")
          output -> Enum.join(lines ++ ["Recent output", output], "\n")
        end
      else
        Enum.join(lines, "\n")
      end
    end)
  end

  defp task_line(task_id) when is_binary(task_id) do
    case Tasks.get(task_id) do
      %{status: status} when is_binary(status) ->
        "[#{task_id}] #{status}"

      _ ->
        "[#{task_id}] missing"
    end
  end

  defp decision_line(%PendingAsk{} = pending_ask) do
    resolution = pending_ask.config["resolution"] || %{}
    actor = resolution["actor_label"]

    label =
      case pending_ask.answer do
        @detach_answer -> "→ Detached"
        @continue_answer -> "→ Continued while waiting"
        @cancel_answer -> "→ Cancelled"
        @check_answer -> "→ Checked background work"
        _ -> "→ Decision recorded"
      end

    if is_binary(actor) and actor != "" do
      label <> " by " <> actor
    else
      label
    end
  end
end
