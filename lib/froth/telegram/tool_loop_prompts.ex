defmodule Froth.Telegram.ToolLoopPrompts do
  @moduledoc """
  Telegram UI helpers for inference tool-loop prompt messages.
  """

  alias Froth.Repo
  alias Froth.Telegram.BotAdapter
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  def send_or_edit_eval_prompt(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    bot_username = Keyword.fetch!(opts, :bot_username)
    inference_session_id = Keyword.fetch!(opts, :inference_session_id)
    chat_id = Keyword.fetch!(opts, :chat_id)
    reply_to = Keyword.fetch!(opts, :reply_to)
    last_message_id = Keyword.get(opts, :last_message_id)

    stop_data = Base.encode64("stoploop:#{inference_session_id}")
    prompt_text = "I want to run code before I reply."

    buttons = [
      %{
        "@type" => "inlineKeyboardButton",
        "text" => "Open",
        "type" => %{
          "@type" => "inlineKeyboardButtonTypeUrl",
          "url" => "https://t.me/#{bot_username}/tool?startapp=session_#{inference_session_id}"
        }
      },
      %{
        "@type" => "inlineKeyboardButton",
        "text" => "Stop",
        "type" => %{
          "@type" => "inlineKeyboardButtonTypeCallback",
          "data" => stop_data
        }
      }
    ]

    with {:ok, message_id, action} <-
           send_or_edit_prompt(
             session_id,
             chat_id,
             reply_to,
             last_message_id,
             prompt_text,
             buttons
           ) do
      {:ok, message_id, action}
    end
  end

  def sync_pending_prompt_message_id(bot_id, old_id, new_id, chat_id)
      when is_binary(bot_id) and is_integer(chat_id) do
    case Repo.one(
           from(c in InferenceSession,
             where:
               c.bot_id == ^bot_id and c.status == "awaiting_tools" and c.chat_id == ^chat_id,
             order_by: [desc: c.id],
             limit: 1
           ),
           log: false
         ) do
      nil ->
        :ok

      inference_session ->
        if Enum.any?(inference_session.pending_tools, &(&1["approval_msg_id"] == old_id)) do
          pending_tools =
            Enum.map(inference_session.pending_tools, fn tool ->
              if tool["approval_msg_id"] == old_id do
                %{tool | "approval_msg_id" => new_id}
              else
                tool
              end
            end)

          inference_session
          |> InferenceSession.changeset(%{pending_tools: pending_tools})
          |> Repo.update!()
        end
    end

    :ok
  end

  defp send_or_edit_prompt(
         session_id,
         chat_id,
         reply_to,
         last_message_id,
         prompt_text,
         buttons
       ) do
    case last_message_id do
      message_id when is_integer(message_id) ->
        case edit_prompt_message(session_id, chat_id, message_id, prompt_text, buttons) do
          {:ok, _} ->
            {:ok, message_id, "edit"}

          _ ->
            send_prompt_message(session_id, chat_id, reply_to, prompt_text, buttons)
        end

      _ ->
        send_prompt_message(session_id, chat_id, reply_to, prompt_text, buttons)
    end
  end

  defp send_prompt_message(session_id, chat_id, reply_to, prompt_text, buttons) do
    case BotAdapter.send_message(session_id, chat_id, prompt_text,
           reply_to: reply_to,
           reply_markup: %{
             "@type" => "replyMarkupInlineKeyboard",
             "rows" => [buttons]
           }
         ) do
      {:ok, %{"id" => msg_id}} when is_integer(msg_id) ->
        {:ok, msg_id, "send"}

      other ->
        {:error, other}
    end
  end

  defp edit_prompt_message(session_id, chat_id, msg_id, prompt_text, buttons) do
    BotAdapter.edit_message_text(session_id, chat_id, msg_id, prompt_text,
      reply_markup: %{
        "@type" => "replyMarkupInlineKeyboard",
        "rows" => [buttons]
      }
    )
  end
end
