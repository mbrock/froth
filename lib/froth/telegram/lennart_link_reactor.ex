defmodule Froth.Telegram.LennartLinkReactor do
  @moduledoc """
  Lennart reacts to any link posted by a human in the group chat.

  Subscribes to Charlie's TDLib update stream (which sees everything),
  detects URLs in human messages, and sends a reaction from the agentbot
  session. Excludes *.foo domains to avoid noise from internal links.
  """
  use GenServer
  require Logger

  @charlie_topic "telegram:charlie"
  @lennart_session "agentbot"
  @group_chat_id -1003690254489

  # Known human user IDs
  @human_user_ids [
    1_635_262_887,  # Daniel
    362_441_422,    # Mikael
    6_071_676_050   # Patty
  ]

  # Match URLs but we'll filter out *.foo domains after
  @url_re ~r{https?://[^\s<>]+}

  # Internal domains to ignore
  @ignored_domain_re ~r{https?://[^\s/]*\.foo(?:[/\s]|$)}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_state) do
    Phoenix.PubSub.subscribe(Froth.PubSub, @charlie_topic)
    Logger.info("LennartLinkReactor: online")
    {:ok, %{reacted: 0}}
  end

  def handle_info(
        {:telegram_update, %{"@type" => "updateNewMessage", "message" => msg}},
        state
      ) do
    sender_id = get_in(msg, ["sender_id", "user_id"])
    chat_id = msg["chat_id"]
    text = get_text(msg)

    if sender_id in @human_user_ids and chat_id == @group_chat_id and has_external_link?(text) do
      react(chat_id, msg["id"])
      {:noreply, %{state | reacted: state.reacted + 1}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp get_text(%{"content" => %{"text" => %{"text" => text}}}) when is_binary(text), do: text
  defp get_text(%{"content" => %{"caption" => %{"text" => text}}}) when is_binary(text), do: text
  defp get_text(_), do: ""

  defp has_external_link?(text) do
    case Regex.scan(@url_re, text) do
      [] -> false
      urls ->
        Enum.any?(urls, fn [url] ->
          not Regex.match?(@ignored_domain_re, url)
        end)
    end
  end

  defp react(chat_id, message_id) do
    Froth.Telegram.send(@lennart_session, %{
      "@type" => "setMessageReactions",
      "chat_id" => chat_id,
      "message_id" => message_id,
      "reaction_types" => [%{"@type" => "reactionTypeEmoji", "emoji" => "👀"}],
      "is_big" => false
    })
  end
end
