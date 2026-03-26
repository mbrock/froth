defmodule Froth.Telegram.LennartLinkReactor do
  @moduledoc """
  Lennart responds to any external link posted by a human.

  Subscribes to Charlie's TDLib update stream (which sees everything),
  detects URLs in human messages, and forwards the message directly to
  Lennart's Bot process with trigger metadata so he can react without
  pretending the user explicitly mentioned him.

  Excludes *.foo domains to avoid noise from internal links.
  """
  use GenServer
  require Logger

  @charlie_topic "telegram:charlie"
  @group_chat_id -1_003_690_254_489

  # Known human user IDs
  @human_user_ids [
    # Daniel
    1_635_262_887,
    # Mikael
    362_441_422,
    # Patty
    6_071_676_050
  ]

  # Match URLs
  @url_re ~r{https?://[^\s<>]+}

  # Internal domains to ignore
  @ignored_domain_re ~r{https?://[^\s/]*\.foo(?:[/\s]|$)}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_state) do
    Phoenix.PubSub.subscribe(Froth.PubSub, @charlie_topic)
    Logger.info("LennartLinkReactor: online — links trigger Lennart agent cycles")
    {:ok, %{forwarded: 0}}
  end

  def handle_info(
        {:telegram_update, %{"@type" => "updateNewMessage", "message" => msg} = _update},
        state
      ) do
    sender_id = get_in(msg, ["sender_id", "user_id"])
    chat_id = msg["chat_id"]
    text = get_text(msg)

    if sender_id in @human_user_ids and chat_id == @group_chat_id and has_external_link?(text) do
      forward_to_lennart(msg)
      {:noreply, %{state | forwarded: state.forwarded + 1}}
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
      [] ->
        false

      urls ->
        Enum.any?(urls, fn [url] ->
          not Regex.match?(@ignored_domain_re, url)
        end)
    end
  end

  defp forward_to_lennart(msg) do
    tagged_msg =
      Map.update(msg, "froth_meta", %{"trigger" => "link_reactor"}, fn
        meta when is_map(meta) -> Map.put(meta, "trigger", "link_reactor")
        _other -> %{"trigger" => "link_reactor"}
      end)

    case Registry.lookup(Froth.Telegram.BotRegistry, "lennart") do
      [{pid, _}] ->
        GenServer.cast(pid, {:start_inference_session, tagged_msg})
        Logger.info("LennartLinkReactor: forwarded link to Lennart with link-trigger metadata")

      [] ->
        Logger.warning("LennartLinkReactor: Lennart bot not found in registry")
    end
  end
end
