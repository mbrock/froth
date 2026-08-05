defmodule Froth.Telegram.BotTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Agent.Cycle
  alias Froth.Telegram.{Bot, Message, SessionConfig}
  alias LLM.Request

  test "idle struct has no cycle_state" do
    assert %Bot{cycle_state: nil} = %Bot{}
  end

  test "telegram error updates do not crash the bot" do
    %{bot: bot} = start_charlie_bot()
    ref = Process.monitor(bot)

    send(
      bot,
      {:telegram_update,
       %{"@type" => "error", "code" => 400, "message" => "MESSAGE_ID_INVALID"}}
    )

    assert %Bot{} = :sys.get_state(bot)
    refute_receive {:DOWN, ^ref, :process, ^bot, _reason}, 100
  end

  test "messages from before bot startup do not trigger catch-up replies" do
    chat_id = 362_441_422

    %{bot: bot} =
      start_charlie_bot(trigger_not_before: 2_000_000_000)

    send(
      bot,
      user_update("old mention",
        message_id: 9,
        chat_id: chat_id,
        date: 1_999_999_999
      )
    )

    _ = :sys.get_state(bot)
    refute_receive {FakeLLM, _turn, %Request{}}, 100

    send(
      bot,
      user_update("fresh mention",
        message_id: 10,
        chat_id: chat_id,
        date: 2_000_000_000
      )
    )

    assert_receive {FakeLLM, turn, %Request{}}, 5_000
    reply_turns_until_idle(bot, turn)
  end

  test "triggering messages queue while a cycle is active and drain one at a time" do
    chat_id = 362_441_422
    %{bot: bot} = start_charlie_bot()

    send(bot, user_update("first", message_id: 10, chat_id: chat_id))

    assert_receive {FakeLLM, turn_1, %Request{}}, 5_000

    send(bot, user_update("second", message_id: 11, chat_id: chat_id))
    send(bot, user_update("third", message_id: 12, chat_id: chat_id))

    assert :sys.get_state(bot).pending_messages |> :queue.len() == 2
    refute_receive {FakeLLM, _turn, %Request{}}, 200

    FakeLLM.reply(turn_1, {:ok, text_response("first done")})

    assert_receive {FakeLLM, turn_2, %Request{}}, 5_000

    state = :sys.get_state(bot)
    assert state.cycle_state
    assert :queue.len(state.pending_messages) == 1
    refute_receive {FakeLLM, _turn, %Request{}}, 200

    FakeLLM.reply(turn_2, {:ok, text_response("second done")})

    assert_receive {FakeLLM, turn_3, %Request{}}, 5_000

    state = :sys.get_state(bot)
    assert state.cycle_state
    assert :queue.is_empty(state.pending_messages)

    reply_turns_until_idle(bot, turn_3)
  end

  test "queued turns see replies and chat activity produced while waiting" do
    chat_id = 362_441_422
    now = System.system_time(:second)

    %{bot: bot, session_id: session_id} =
      start_charlie_bot(trigger_not_before: now - 30)

    Repo.insert!(
      SessionConfig.changeset(%SessionConfig{}, %{
        id: session_id,
        api_id: 1,
        api_hash: "test",
        bot_token: "test"
      })
    )

    send(
      bot,
      user_update("first", message_id: 20, chat_id: chat_id, date: now - 20)
    )

    assert_receive {FakeLLM, turn_1, %Request{}}, 5_000

    send(
      bot,
      user_update("second", message_id: 21, chat_id: chat_id, date: now - 10)
    )

    Repo.insert!(%Message{
      telegram_session_id: session_id,
      chat_id: chat_id,
      message_id: 22,
      sender_id: 1,
      date: now,
      raw: %{
        "id" => 22,
        "chat_id" => chat_id,
        "sender_id" => %{"user_id" => 1},
        "date" => now,
        "content" => %{"text" => %{"text" => "intervening Charlie reply"}}
      }
    })

    FakeLLM.reply(turn_1, {:ok, text_response("first done")})

    assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5_000

    request_text =
      request_2.messages
      |> Enum.flat_map(fn message -> List.wrap(message.content) end)
      |> Enum.map_join("\n", fn
        %{"text" => text} -> text
        block -> inspect(block)
      end)

    assert request_text =~ "intervening Charlie reply"
    assert request_text =~ "second"

    reply_turns_until_idle(bot, turn_2)
  end

  test "pending message queue is capped by dropping the oldest queued triggers" do
    chat_id = 362_441_422
    %{bot: bot} = start_charlie_bot()

    send(bot, user_update("first", message_id: 10, chat_id: chat_id))

    assert_receive {FakeLLM, turn_1, %Request{}}, 5_000

    for message_id <- 11..23 do
      send(
        bot,
        user_update("queued #{message_id}",
          message_id: message_id,
          chat_id: chat_id
        )
      )
    end

    state = :sys.get_state(bot)
    assert :queue.len(state.pending_messages) == 10

    {{:value, next_msg}, _pending_messages} =
      :queue.out(state.pending_messages)

    assert next_msg["id"] == 14

    FakeLLM.reply(turn_1, {:ok, text_response("first done")})

    assert_receive {FakeLLM, turn_2, %Request{}}, 5_000

    reply_turns_until_idle(bot, turn_2)
  end

  test "debounce fire starts an idle cycle instead of debouncing again" do
    chat_id = 362_441_422
    %{bot: bot} = start_charlie_bot(debounce_ms: 10_000)

    send(bot, user_update("first", message_id: 10, chat_id: chat_id))

    state = :sys.get_state(bot)
    assert state.cycle_state == nil
    assert state.debounce_msg["id"] == 10

    send(bot, :debounce_fire)

    assert_receive {FakeLLM, turn_1, %Request{}}, 5_000

    state = :sys.get_state(bot)
    assert state.cycle_state
    assert state.debounce_msg == nil

    reply_turns_until_idle(bot, turn_1)
  end

  test "cycle footer edits the final message with cache stats when a cycle finishes" do
    %{bot: bot} = start_charlie_bot()

    started_at = DateTime.utc_now() |> DateTime.add(-12, :second)

    cycle =
      Repo.insert!(%Cycle{
        usage: %{
          "input_tokens" => 1_200,
          "output_tokens" => 300,
          "cache_creation_input_tokens" => 400,
          "cache_read_input_tokens" => 2_500
        },
        cost_usd: 0.012,
        started_at: started_at
      })

    {:ok, runtime_pid} =
      Froth.Agent.CycleRuntime.start_for_bot(
        bot,
        cycle: cycle,
        cycle_id: cycle.id,
        chat_id: 123
      )

    :sys.replace_state(runtime_pid, fn rstate ->
      put_in(rstate.context.view.last_sent, %{id: 42, text: "hello"})
    end)

    ref = Process.monitor(runtime_pid)
    stop_runtime(runtime_pid)
    assert_receive {:DOWN, ^ref, :process, ^runtime_pid, _}, 5_000

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "chat_id" => 123,
                      "message_id" => 42,
                      "input_message_content" => %{
                        "text" => %{"text" => edited_text}
                      }
                    }},
                   5_000

    assert edited_text =~ "hello"
    assert edited_text =~ "4.1k in"
    assert edited_text =~ "0.3k out"
    assert edited_text =~ "0.4k cw"
    assert edited_text =~ "2.5k cr"
    assert edited_text =~ "$"
  end

  defp stop_runtime(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  defp reply_turns_until_idle(bot, turn, remaining \\ 20)

  defp reply_turns_until_idle(bot, turn, remaining) when remaining > 0 do
    FakeLLM.reply(turn, {:ok, text_response("done")})

    receive do
      {FakeLLM, next_turn, %Request{}} ->
        reply_turns_until_idle(bot, next_turn, remaining - 1)
    after
      500 ->
        assert_bot_idle(bot)
    end
  end

  defp reply_turns_until_idle(_bot, _turn, 0) do
    flunk("bot did not drain queued turns")
  end

  defp assert_bot_idle(bot, attempts \\ 200)

  defp assert_bot_idle(bot, attempts) when is_pid(bot) and attempts > 0 do
    case :sys.get_state(bot) do
      %{
        cycle_state: nil,
        pending_ask_resumes: [],
        pending_messages: pending_messages
      } ->
        if :queue.is_empty(pending_messages) do
          :ok
        else
          wait_for_idle(bot, attempts)
        end

      _state ->
        wait_for_idle(bot, attempts)
    end
  end

  defp assert_bot_idle(_bot, 0) do
    flunk("bot did not become idle in time")
  end

  defp wait_for_idle(bot, attempts) do
    receive do
    after
      20 -> assert_bot_idle(bot, attempts - 1)
    end
  end

  defp text_response(text) do
    %{
      text: text,
      content: [%{"type" => "text", "text" => text}],
      stop_reason: "end_turn"
    }
  end

  defp user_update(text, opts) do
    chat_id = Keyword.get(opts, :chat_id, 362_441_422)
    message_id = Keyword.fetch!(opts, :message_id)
    sender_user_id = Keyword.get(opts, :sender_user_id, 777)
    date = Keyword.get(opts, :date, System.system_time(:second))

    {:telegram_update,
     %{
       "@type" => "updateNewMessage",
       "message" =>
         %{
           "id" => message_id,
           "chat_id" => chat_id,
           "sender_id" => %{"user_id" => sender_user_id},
           "content" => %{"text" => %{"text" => text}}
         }
         |> maybe_put_date(date)
     }}
  end

  defp maybe_put_date(message, date) when is_integer(date),
    do: Map.put(message, "date", date)

  defp maybe_put_date(message, _date), do: message
end
