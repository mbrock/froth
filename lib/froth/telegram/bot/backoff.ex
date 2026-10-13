defmodule Froth.Telegram.Bot.Backoff do
  @moduledoc """
  Clock-free group wake backoff. Counts bot messages, including our own,
  since the last confirmed human message. State is local to each bot runtime.
  """

  alias Froth.Telegram.Message

  defstruct counts: %{}, users: %{}

  def cache_user(state, %{"id" => id, "type" => %{"@type" => type}})
      when type in ["userTypeBot", "userTypeRegular"] do
    %{state | users: Map.put(state.users, id, type == "userTypeBot")}
  end

  def cache_user(state, _user), do: state

  # Unknown/chat senders cannot establish that a human spoke. Count them
  # conservatively, but never cache a failed lookup as a bot or a human.
  def observe(state, msg, own_user_id, lookup) do
    case Message.chat_id(msg) do
      chat_id when is_integer(chat_id) and chat_id < 0 ->
        user_id = Message.sender_user_id(msg)

        state =
          if is_integer(user_id) and user_id != own_user_id and
               not Map.has_key?(state.users, user_id) do
            case lookup.(user_id) do
              {:ok, user} -> cache_user(state, user)
              _ -> state
            end
          else
            state
          end

        human? =
          user_id != own_user_id and Map.get(state.users, user_id) == false

        count = if human?, do: 0, else: Map.get(state.counts, chat_id, 0) + 1
        %{state | counts: Map.put(state.counts, chat_id, count)}

      _ ->
        state
    end
  end

  @doc "Returns the wake decision and suppression metadata; random yields values in [0, 1]."
  def decide(state, chat_id, base, random \\ &:rand.uniform/0) do
    count = Map.get(state.counts, chat_id, 0)

    if chat_id > 0 or count == 0 or base == false do
      {true, %{chat_id: chat_id, count: count, probability: 1.0, roll: nil}}
    else
      unless is_number(base) and base > 1 do
        raise ArgumentError,
              "telegram bot backoff base must be greater than 1 or false"
      end

      probability =
        min(1.0, max(0.0, :math.pow(base, -count) * (0.8 + 0.4 * random.())))

      roll = random.()

      {roll < probability,
       %{chat_id: chat_id, count: count, probability: probability, roll: roll}}
    end
  end
end
