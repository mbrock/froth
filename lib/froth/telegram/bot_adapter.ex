defmodule Froth.Telegram.BotAdapter do
  @moduledoc """
  Telegram transport adapter for bot workers.

  This module contains Telegram-specific concerns such as mention/access checks
  and message send/edit helpers.
  """

  require Logger

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(Froth.PubSub, Froth.Telegram.Session.topic(session_id))
  end

  def mentioned?(msg, bot_username, bot_user_id)
      when is_map(msg) and is_binary(bot_username) and is_integer(bot_user_id) do
    text = get_in(msg, ["content", "text", "text"]) || ""
    entities = get_in(msg, ["content", "text", "entities"]) || []

    String.contains?(text, "@#{bot_username}") or
      Enum.any?(entities, fn e ->
        e["type"]["@type"] == "textEntityTypeMention" and
          String.contains?(String.slice(text, e["offset"], e["length"]), bot_username)
      end) or
      Enum.any?(entities, fn e ->
        e["type"]["@type"] == "textEntityTypeMentionName" and
          e["type"]["user_id"] == bot_user_id
      end)
  end

  def mentioned?(_, _, _), do: false

  def mentioned?(msg, bot_username, bot_user_id, name_triggers)
      when is_map(msg) and is_binary(bot_username) and is_integer(bot_user_id) and
             is_list(name_triggers) do
    mentioned?(msg, bot_username, bot_user_id) or
      name_triggered?(msg, name_triggers)
  end

  defp name_triggered?(msg, triggers) when is_list(triggers) do
    text = get_in(msg, ["content", "text", "text"]) || ""
    downcased = String.downcase(text)
    Enum.any?(triggers, fn trigger -> String.contains?(downcased, String.downcase(trigger)) end)
  end

  def allowed_chat?(chat_id, owner_user_id, _session_id)
      when is_integer(chat_id) and is_integer(owner_user_id) and chat_id > 0 do
    chat_id == owner_user_id
  end

  def allowed_chat?(chat_id, owner_user_id, session_id)
      when is_integer(chat_id) and is_integer(owner_user_id) and is_binary(session_id) do
    cache_key = {:chat_allowed, session_id, chat_id, owner_user_id}

    case Process.get(cache_key) do
      nil ->
        allowed =
          case Froth.Telegram.call(session_id, %{
                 "@type" => "getChatMember",
                 "chat_id" => chat_id,
                 "member_id" => %{
                   "@type" => "messageSenderUser",
                   "user_id" => owner_user_id
                 }
               }) do
            {:ok, %{"status" => %{"@type" => status}}}
            when status in [
                   "chatMemberStatusCreator",
                   "chatMemberStatusAdministrator",
                   "chatMemberStatusMember"
                 ] ->
              true

            _ ->
              false
          end

        Process.put(cache_key, allowed)
        Logger.info(event: :chat_access_check, chat_id: chat_id, allowed: allowed)
        allowed

      allowed ->
        allowed
    end
  end

  def send_message(session_id, chat_id, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and is_binary(text) and is_list(opts) do
    payload = %{
      "@type" => "sendMessage",
      "chat_id" => chat_id,
      "reply_to" => reply_to_msg(opts[:reply_to]),
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => %{
          "@type" => "formattedText",
          "text" => text
        }
      }
    }

    payload =
      case opts[:entities] do
        entities when is_list(entities) ->
          put_in(payload, ["input_message_content", "text", "entities"], entities)

        _ ->
          payload
      end

    payload =
      case opts[:reply_markup] do
        markup when is_map(markup) -> Map.put(payload, "reply_markup", markup)
        _ -> payload
      end

    session_id
    |> Froth.Telegram.call(payload)
    |> normalize_tdlib_result()
  end

  def edit_message_text(session_id, chat_id, message_id, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and is_integer(message_id) and
             is_binary(text) and is_list(opts) do
    payload = %{
      "@type" => "editMessageText",
      "chat_id" => chat_id,
      "message_id" => message_id,
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => %{
          "@type" => "formattedText",
          "text" => text
        }
      }
    }

    payload =
      case opts[:entities] do
        entities when is_list(entities) ->
          put_in(payload, ["input_message_content", "text", "entities"], entities)

        _ ->
          payload
      end

    payload =
      case opts[:reply_markup] do
        markup when is_map(markup) -> Map.put(payload, "reply_markup", markup)
        _ -> payload
      end

    session_id
    |> Froth.Telegram.call(payload)
    |> normalize_tdlib_result()
  end

  def edit_message_italic(session_id, chat_id, message_id, text)
      when is_binary(session_id) and is_integer(chat_id) and is_integer(message_id) and
             is_binary(text) do
    edit_message_text(session_id, chat_id, message_id, text,
      entities: [
        %{
          "@type" => "textEntity",
          "offset" => 0,
          "length" => String.length(text),
          "type" => %{"@type" => "textEntityTypeItalic"}
        }
      ]
    )
  end

  def send_error(session_id, chat_id, message)
      when is_binary(session_id) and is_integer(chat_id) and is_binary(message) do
    text = "ERROR: #{message}"

    send_message(session_id, chat_id, text,
      entities: [
        %{
          "@type" => "textEntity",
          "offset" => 0,
          "length" => String.length(text),
          "type" => %{"@type" => "textEntityTypeBold"}
        }
      ]
    )
  end

  def send_italic(session_id, chat_id, reply_to, text)
      when is_binary(session_id) and is_integer(chat_id) and is_binary(text) do
    send_message(session_id, chat_id, text,
      reply_to: reply_to,
      entities: [
        %{
          "@type" => "textEntity",
          "offset" => 0,
          "length" => String.length(text),
          "type" => %{"@type" => "textEntityTypeItalic"}
        }
      ]
    )
  end

  def send_typing(session_id, chat_id)
      when is_binary(session_id) and is_integer(chat_id) do
    Froth.Telegram.send(session_id, %{
      "@type" => "sendChatAction",
      "chat_id" => chat_id,
      "action" => %{"@type" => "chatActionTyping"}
    })
  end

  def answer_callback(session_id, callback_query_id)
      when is_binary(session_id) and is_integer(callback_query_id) do
    Froth.Telegram.send(session_id, %{
      "@type" => "answerCallbackQuery",
      "callback_query_id" => callback_query_id
    })
  end

  defp reply_to_msg(nil), do: nil

  defp reply_to_msg(message_id) when is_integer(message_id) do
    %{"@type" => "inputMessageReplyToMessage", "message_id" => message_id}
  end

  defp normalize_tdlib_result({:ok, %{"@type" => "error", "message" => message}})
       when is_binary(message) do
    {:error, message}
  end

  defp normalize_tdlib_result({:ok, %{"@type" => "error"} = error}) do
    {:error, inspect(error)}
  end

  defp normalize_tdlib_result(result), do: result
end
