defmodule Froth.Telegram.Bot.BackoffTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Bot.Backoff

  test "all bot messages count, including our own; humans reset only their chat" do
    lookup = fn id ->
      {:ok, user(id, if(id == 3, do: "userTypeRegular", else: "userTypeBot"))}
    end

    state = Backoff.observe(%Backoff{}, message(-1, 2), 1, lookup)

    state =
      Backoff.observe(state, message(-1, 1), 1, fn _ ->
        flunk("own user lookup")
      end)

    state = Backoff.observe(state, message(-2, 2), 1, lookup)
    assert state.counts == %{-1 => 2, -2 => 1}

    state = Backoff.observe(state, message(-1, 3), 1, lookup)
    assert state.counts == %{-1 => 0, -2 => 1}

    assert {true, %{probability: 1.0}} =
             Backoff.decide(state, -1, 2, fn -> flunk("human roll") end)
  end

  test "user types are cached per id and refreshed by user updates" do
    lookup = fn id -> {:ok, user(id, "userTypeBot")} end
    state = Backoff.observe(%Backoff{}, message(-1, 2), 1, lookup)

    state =
      Backoff.observe(state, message(-2, 2), 1, fn _ ->
        flunk("cached user lookup")
      end)

    state = Backoff.cache_user(state, user(2, "userTypeRegular"))

    state =
      Backoff.observe(state, message(-1, 2), 1, fn _ ->
        flunk("cached human lookup")
      end)

    assert state.counts == %{-1 => 0, -2 => 1}
  end

  test "failed lookups retry and unknown or chat senders do not reset" do
    state =
      Backoff.observe(%Backoff{}, message(-1, 2), 1, fn _ ->
        {:error, :unavailable}
      end)

    assert state.users == %{}

    state =
      Backoff.observe(state, message(-1, nil), 1, fn _ ->
        flunk("chat lookup")
      end)

    assert state.counts[-1] == 2

    state =
      Backoff.observe(state, message(-1, 2), 1, fn id ->
        {:ok, user(id, "userTypeRegular")}
      end)

    assert state.counts[-1] == 0
  end

  test "DMs and disabled backoff never roll" do
    state = %Backoff{counts: %{-1 => 100, 1 => 100}}
    random = fn -> flunk("exempt roll") end
    assert {true, _} = Backoff.decide(state, 1, 2, random)
    assert {true, _} = Backoff.decide(state, -1, false, random)

    assert %Backoff{} ==
             Backoff.observe(%Backoff{}, message(1, 2), 1, fn _ ->
               flunk("DM lookup")
             end)
  end

  test "exponential probabilities and configurable base" do
    for {count, probability} <- [{0, 1.0}, {1, 0.5}, {2, 0.25}, {3, 0.125}] do
      state = %Backoff{counts: %{-1 => count}}

      assert {_, %{probability: ^probability}} =
               Backoff.decide(state, -1, 2, fn -> 0.5 end)
    end

    assert {false, %{probability: 0.0625}} =
             Backoff.decide(%Backoff{counts: %{-1 => 2}}, -1, 4, fn -> 0.5 end)
  end

  test "independent jitter and roll control suppression, including underflow" do
    state = %Backoff{counts: %{-1 => 1}}

    assert {false, %{probability: 0.4, roll: 0.45}} =
             Backoff.decide(state, -1, 2, random([0.0, 0.45]))

    assert {true, %{probability: probability, roll: 0.45}} =
             Backoff.decide(state, -1, 2, random([1.0, 0.45]))

    assert_in_delta probability, 0.6, 1.0e-12

    assert {false, %{probability: 0.0}} =
             Backoff.decide(%Backoff{counts: %{-1 => 10_000}}, -1, 2, fn ->
               0.0
             end)
  end

  defp random(values) do
    key = make_ref()
    Process.put(key, values)

    fn ->
      [value | rest] = Process.get(key)
      Process.put(key, rest)
      value
    end
  end

  defp message(chat_id, user_id),
    do: %{"chat_id" => chat_id, "sender_id" => %{"user_id" => user_id}}

  defp user(id, type), do: %{"id" => id, "type" => %{"@type" => type}}
end
