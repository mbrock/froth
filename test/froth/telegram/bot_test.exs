defmodule Froth.Telegram.BotTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Agent.Cycle
  alias Froth.Telegram.Bot

  test "idle struct has no cycle_state" do
    assert %Bot{cycle_state: nil} = %Bot{}
  end

  test "telegram error updates do not crash the bot" do
    %{bot: bot} = start_charlie_bot()
    ref = Process.monitor(bot)

    send(
      bot,
      {:telegram_update, %{"@type" => "error", "code" => 400, "message" => "MESSAGE_ID_INVALID"}}
    )

    assert %Bot{} = :sys.get_state(bot)
    refute_receive {:DOWN, ^ref, :process, ^bot, _reason}, 100
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

    bot_config = :sys.get_state(bot).bot_config

    {:ok, runtime_pid} =
      Froth.Agent.CycleRuntime.start_root(
        cycle_id: cycle.id,
        cycle: cycle,
        bot_config: bot_config,
        bot_pid: bot,
        chat_id: 123
      )

    :sys.replace_state(runtime_pid, fn rstate ->
      put_in(rstate.context.view.last_sent, %{id: 42, text: "hello"})
    end)

    on_exit(fn ->
      if Process.alive?(runtime_pid) do
        DynamicSupervisor.terminate_child(Froth.Agent.CycleSupervisor, runtime_pid)
      end
    end)

    :ok = DynamicSupervisor.terminate_child(Froth.Agent.CycleSupervisor, runtime_pid)

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "chat_id" => 123,
                      "message_id" => 42,
                      "input_message_content" => %{"text" => %{"text" => edited_text}}
                    }},
                   5_000

    assert edited_text =~ "hello"
    assert edited_text =~ "4.1k in"
    assert edited_text =~ "0.3k out"
    assert edited_text =~ "0.4k cw"
    assert edited_text =~ "2.5k cr"
    assert edited_text =~ "$"
  end
end
