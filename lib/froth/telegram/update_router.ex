defmodule Froth.Telegram.UpdateRouter do
  @moduledoc """
  Parses Telegram updates into normalized bot runtime actions.
  """

  alias Froth.Telegram.BotAdapter

  def route_update(update, opts) when is_map(update) and is_list(opts) do
    case update do
      %{"@type" => "updateNewMessage", "message" => msg} ->
        route_new_message(msg, opts)

      %{"@type" => "updateNewCallbackQuery"} = query ->
        route_callback_query(query)

      %{
        "@type" => "updateMessageSendSucceeded",
        "old_message_id" => old_id,
        "message" => %{"id" => new_id, "chat_id" => chat_id}
      } ->
        {:sync_prompt_message_id, old_id, new_id, chat_id}

      %{"@type" => "updateMessageSendFailed"} ->
        {:message_send_failed, update}

      _ ->
        :ignore
    end
  end

  def route_update(_, _), do: :ignore

  defp route_new_message(msg, opts) when is_map(msg) do
    bot_username = Keyword.fetch!(opts, :bot_username)
    bot_user_id = Keyword.fetch!(opts, :bot_user_id)
    owner_user_id = Keyword.fetch!(opts, :owner_user_id)
    session_id = Keyword.fetch!(opts, :session_id)

    sender = get_in(msg, ["sender_id", "user_id"])

    is_reply_to_bot = replied_to_bot?(msg, bot_user_id)

    cond do
      sender == bot_user_id ->
        :ignore

      (BotAdapter.mentioned?(msg, bot_username, bot_user_id, Keyword.get(opts, :name_triggers, [])) or
         is_reply_to_bot) and
          BotAdapter.allowed_chat?(msg["chat_id"], owner_user_id, session_id) ->
        {:start_inference_session, msg}

      true ->
        :ignore
    end
  end

  defp route_new_message(_, _), do: :ignore

  defp replied_to_bot?(msg, bot_user_id) when is_map(msg) and is_integer(bot_user_id) do
    case msg do
      %{"reply_to" => %{"@type" => "messageReplyToMessage", "message_id" => reply_msg_id, "chat_id" => chat_id}}
          when is_integer(reply_msg_id) and is_integer(chat_id) ->
        # Look up whether the replied-to message was sent by this bot
        import Ecto.Query, only: [from: 2]

        case Froth.Repo.one(
               from(m in "telegram_messages",
                 where: m.chat_id == ^chat_id and m.message_id == ^reply_msg_id,
                 select: m.sender_id
               )
             ) do
          ^bot_user_id -> true
          _ -> false
        end

      _ ->
        false
    end
  end

    defp route_callback_query(query) do
    case parse_callback_payload(query) do
      {:ok, action, arg} ->
        query_id = query["id"]

        callback_action =
          case action do
            "stoploop" ->
              case Integer.parse(arg) do
                {inference_session_id, ""} -> {:stop_loop, inference_session_id}
                _ -> :ignore
              end

            _ ->
              {:resolve_tool, arg, action}
          end

        if is_integer(query_id) do
          {:callback, query_id, callback_action}
        else
          :ignore
        end

      :error ->
        :ignore
    end
  end

  defp parse_callback_payload(%{
         "payload" => %{"@type" => "callbackQueryPayloadData", "data" => data_b64}
       }) do
    with {:ok, data} <- Base.decode64(data_b64),
         [action, arg] when action in ["go", "skip", "stop", "stoploop"] <-
           String.split(data, ":", parts: 2) do
      {:ok, action, arg}
    else
      _ -> :error
    end
  end

  defp parse_callback_payload(_), do: :error
end
