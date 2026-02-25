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

    cond do
      sender == bot_user_id ->
        :ignore

      BotAdapter.mentioned?(msg, bot_username, bot_user_id, Keyword.get(opts, :name_triggers, [])) and
          BotAdapter.allowed_chat?(msg["chat_id"], owner_user_id, session_id) ->
        {:start_inference_session, msg}

      true ->
        :ignore
    end
  end

  defp route_new_message(_, _), do: :ignore

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
