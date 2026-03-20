defmodule Froth.CharlieLennartBridge do
  @moduledoc """
  Bridges Charlie's TDLib session to Lennart's bot process.

  Telegram bots cannot see other bots' messages (privacy mode).
  Charlie's TDLib session sees everything in the group. This bridge
  subscribes to Charlie's update stream and forwards bot messages
  that Lennart's agentbot session would otherwise miss.
  """
  use GenServer
  require Logger

  @charlie_topic "telegram:charlie"
  @bot_user_ids [
    6_789_382_533,
    8_044_965_953,
    8_396_222_696,
    8_507_666_754,
    8_526_337_359,
    8_534_404_418
  ]

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_state) do
    Phoenix.PubSub.subscribe(Froth.PubSub, @charlie_topic)
    Logger.info("CharlieLennartBridge: online")
    {:ok, %{forwarded: 0}}
  end

  def handle_info(
        {:telegram_update, %{"@type" => "updateNewMessage", "message" => msg} = update},
        state
      ) do
    sender_id = get_in(msg, ["sender_id", "user_id"])

    if sender_id in @bot_user_ids do
      forward_to_lennart(update)
      {:noreply, %{state | forwarded: state.forwarded + 1}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:telegram_update, %{"@type" => "updateMessageSendSucceeded", "message" => msg}},
        state
      ) do
    forward_to_lennart(%{"@type" => "updateNewMessage", "message" => msg})
    {:noreply, %{state | forwarded: state.forwarded + 1}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp forward_to_lennart(update) do
    case Registry.lookup(Froth.Telegram.BotRegistry, "lennart") do
      [{pid, _}] -> send(pid, {:telegram_update, update})
      [] -> :ok
    end
  end
end
