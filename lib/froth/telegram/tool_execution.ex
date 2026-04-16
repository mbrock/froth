defmodule Froth.Telegram.ToolExecution do
  @moduledoc false

  alias Froth.Agent.{FailureIntervention, ToolDescription}
  alias Froth.Inference.Tools
  alias Froth.Telegram.BotAdapter
  alias Froth.Telegram.ControlPrompt

  @telegram_text_limit 4096

  def execute(%{name: "send_message", spam: false}) do
    %{result: {:ok, "suppressed"}}
  end

  def execute(%{
        name: "send_message",
        input: %{"text" => text},
        session_id: session_id,
        chat_id: chat_id,
        reply_to: reply_to
      })
      when is_binary(text) and is_binary(session_id) and is_integer(chat_id) do
    case BotAdapter.send_message(session_id, chat_id, text, reply_to: reply_to) do
      {:ok, sent} ->
        %{
          result: {:ok, "sent"},
          sent_message: %{
            sent: sent,
            text: text
          }
        }

      {:error, reason} ->
        %{result: {:error, inspect(reason)}}
    end
  end

  def execute(
        %{
          name: name,
          input: input,
          session_id: session_id,
          bot_id: bot_id,
          bot_username: bot_username,
          chat_id: chat_id
        } = execution
      )
      when is_binary(name) and is_map(input) and is_binary(session_id) and is_binary(bot_id) and
             is_integer(chat_id) do
    spam = Map.get(execution, :spam, true)
    reply_to = Map.get(input, "reply_to") || Map.get(input, :reply_to) || execution[:reply_to]

    tool_opts =
      [
        bot_id: bot_id,
        bot_username: bot_username,
        cycle_id: execution[:cycle_id],
        session_id: session_id,
        reply_to: execution[:reply_to]
      ]
      |> maybe_put_tool_opt(:spam, execution[:spam])
      |> maybe_put_tool_opt(:topic, input["topic"])
      |> maybe_put_tool_opt(:active_task_ids, execution[:active_task_ids])
      |> maybe_put_tool_opt(:tool_use_id, execution[:tool_use_id])
      |> maybe_put_tool_opt(:system_prompt, execution[:system_prompt])
      |> maybe_put_tool_opt(:model, execution[:model])
      |> maybe_put_tool_opt(:tools, execution[:tools])
      |> maybe_put_tool_opt(:thinking, execution[:thinking])
      |> maybe_put_tool_opt(:effort, execution[:effort])
      |> maybe_put_tool_opt(:tool_timeout_ms, execution[:tool_timeout_ms])

    narration_message = maybe_send_narration(input, execution, reply_to, spam)

    result =
      case name do
        "elixir_eval" ->
          Tools.execute(name, input, chat_id, tool_opts)

        "run_shell" ->
          Tools.execute(name, input, chat_id, tool_opts)

        _ ->
          Tools.execute(name, input, chat_id, tool_opts)
      end

    case FailureIntervention.maybe_intervene(result, execution) do
      %{result: _} = outcome ->
        Map.put(outcome, :narration_message, narration_message)

      updated_result ->
        build_tool_outcome(updated_result, narration_message, input)
    end
  end

  def execute(_prepared), do: %{result: {:error, "invalid tool execution context"}}

  defp maybe_send_narration(_input, _execution, _reply_to, false), do: nil

  defp maybe_send_narration(input, execution, reply_to, true) when is_map(input) do
    case ToolDescription.text_from_input(input) do
      narration when is_binary(narration) and narration != "" ->
        send_or_edit_narration(execution, reply_to, narration, :italic)

      _ ->
        maybe_send_legacy_narration(input, execution, reply_to)
    end
  end

  defp maybe_send_narration(_input, _execution, _reply_to, _spam), do: nil

  defp maybe_send_legacy_narration(%{"narration_markdown" => narration}, execution, reply_to)
       when is_binary(narration) and narration != "" do
    send_or_edit_narration(execution, reply_to, String.trim(narration), :markdown)
  end

  defp maybe_send_legacy_narration(%{"narration" => narration}, execution, reply_to)
       when is_binary(narration) and narration != "" do
    send_or_edit_narration(execution, reply_to, String.trim(narration), :italic)
  end

  defp maybe_send_legacy_narration(_input, _execution, _reply_to), do: nil

  defp send_or_edit_narration(
         %{
           session_id: session_id,
           chat_id: chat_id,
           current_narration_message_id: message_id,
           current_narration_text: current_text,
           current_narration_mode: mode
         } = execution,
         reply_to,
         narration,
         mode
       )
       when is_binary(session_id) and is_integer(chat_id) and is_integer(message_id) and
              is_binary(current_text) and narration != "" do
    combined = append_narration(current_text, narration)

    if String.length(combined) <= @telegram_text_limit do
      case edit_narration(session_id, chat_id, message_id, combined, mode) do
        {:ok, _sent} -> %{message_id: message_id, text: combined, mode: mode}
        {:error, _reason} -> send_new_narration(execution, reply_to, narration, mode)
      end
    else
      send_new_narration(execution, reply_to, narration, mode)
    end
  end

  defp send_or_edit_narration(
         %{session_id: session_id, chat_id: chat_id} = execution,
         reply_to,
         narration,
         mode
       )
       when is_binary(session_id) and is_integer(chat_id) and narration != "" do
    send_new_narration(execution, reply_to, narration, mode)
  end

  defp send_or_edit_narration(_, _, _, _), do: nil

  defp send_new_narration(execution, reply_to, narration, mode) do
    %{session_id: session_id, chat_id: chat_id} = execution
    opts = [reply_markup: cycle_reply_markup(execution)]

    result =
      case mode do
        :markdown -> BotAdapter.send_markdown(session_id, chat_id, reply_to, narration, opts)
        :italic -> BotAdapter.send_italic(session_id, chat_id, reply_to, narration, opts)
      end

    case result do
      {:ok, sent} -> build_narration_message(sent, narration, mode)
      {:error, _reason} -> nil
    end
  end

  defp cycle_reply_markup(%{cycle_id: cycle_id, bot_id: bot_id} = execution)
       when is_binary(cycle_id) and is_binary(bot_id) do
    %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => [
        ControlPrompt.buttons(
          cycle_id: cycle_id,
          bot_id: bot_id,
          bot_username: execution[:bot_username]
        )
      ]
    }
  end

  defp cycle_reply_markup(_execution), do: nil

  defp edit_narration(session_id, chat_id, message_id, narration, :markdown),
    do: BotAdapter.edit_message_markdown(session_id, chat_id, message_id, narration)

  defp edit_narration(session_id, chat_id, message_id, narration, :italic),
    do: BotAdapter.edit_message_italic(session_id, chat_id, message_id, narration)

  defp build_narration_message(sent, text, mode) when is_binary(text) do
    case sent_message_id(sent) do
      id when is_integer(id) -> %{message_id: id, text: text, mode: mode}
      _ -> nil
    end
  end

  defp sent_message_id(%{"id" => id}) when is_integer(id), do: id

  defp sent_message_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp sent_message_id(_), do: nil

  defp append_narration(current_text, narration) do
    existing = String.trim_trailing(current_text)
    addition = String.trim(narration)

    cond do
      existing == "" -> addition
      addition == "" -> existing
      true -> existing <> "\n" <> addition
    end
  end

  defp build_tool_outcome(
         {:await, %{"sent_message" => sent_message} = data},
         narration_message,
         %{"question" => question}
       )
       when is_map(sent_message) and is_binary(question) do
    %{
      result: {:await, Map.delete(data, "sent_message")},
      sent_message: %{sent: sent_message, text: question},
      narration_message: narration_message,
      awaiting_user_input: true
    }
  end

  defp build_tool_outcome(
         {:await, %{"sent_message" => sent_message, "message_text" => message_text} = data},
         narration_message,
         _input
       )
       when is_map(sent_message) and is_binary(message_text) do
    %{
      result: {:await, Map.delete(data, "sent_message")},
      sent_message: %{sent: sent_message, text: message_text},
      narration_message: narration_message,
      awaiting_user_input: true
    }
  end

  defp build_tool_outcome(result, narration_message, _input) do
    %{result: normalize_result(result), narration_message: narration_message}
  end

  defp normalize_result({:await, data}), do: {:await, data}
  defp normalize_result({:yield, reason}), do: {:yield, reason}
  defp normalize_result(result), do: result

  defp maybe_put_tool_opt(keyword, _key, nil), do: keyword
  defp maybe_put_tool_opt(keyword, key, value), do: Keyword.put(keyword, key, value)
end
