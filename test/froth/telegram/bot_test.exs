defmodule Froth.Telegram.BotTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.ToolUse
  alias Froth.Telegram.Bot

  test "struct includes mid-cycle message buffer" do
    assert %Bot{mid_cycle_messages: []} = %Bot{}
  end

  test "prepare_tool reserves the control prompt once per cycle" do
    bot = start_bot()
    tool_use = %ToolUse{id: "call_1", name: "elixir_eval", input: %{"code" => "1 + 1"}}
    context = %{cycle_id: "cycle_1", chat_id: 123, reply_to: 456}

    assert {:ok, %{execution: execution}} =
             GenServer.call(bot, {:prepare_tool, tool_use, context})

    assert execution.input["send_control_prompt"] == true
    assert MapSet.member?(:sys.get_state(bot).control_prompt_cycles, "cycle_1")

    assert {:ok, %{execution: execution_2}} =
             GenServer.call(bot, {:prepare_tool, tool_use, context})

    assert execution_2.input["send_control_prompt"] == false
  end

  test "commit_tool tracks sent messages and injects buffered mid-cycle messages" do
    bot = start_bot()
    tool_use = %ToolUse{id: "call_1", name: "send_message", input: %{"text" => "hello"}}
    context = %{cycle_id: "cycle_1", chat_id: 123, reply_to: 456}

    :sys.replace_state(bot, fn state ->
      %{state | mid_cycle_messages: [%{text: "new incoming"}]}
    end)

    outcome = %{
      result: {:ok, "sent"},
      sent_message: %{
        sent: %{"id" => 42},
        text: "hello"
      }
    }

    assert {:ok, result_text} =
             GenServer.call(
               bot,
               {:commit_tool, tool_use, context, %{execution: %{cycle_id: "cycle_1"}}, outcome}
             )

    assert result_text =~ "sent"
    assert result_text =~ "Message received during tool execution: new incoming"

    state = :sys.get_state(bot)
    assert state.cycle_replied? == true
    assert state.last_sent_message_id == 42
    assert state.last_sent_message_text == "hello"
    assert state.mid_cycle_messages == []
  end

  test "telegram error updates do not crash the bot" do
    bot = start_bot()
    ref = Process.monitor(bot)

    send(
      bot,
      {:telegram_update, %{"@type" => "error", "code" => 400, "message" => "MESSAGE_ID_INVALID"}}
    )

    assert %Bot{} = :sys.get_state(bot)
    refute_receive {:DOWN, ^ref, :process, ^bot, _reason}, 100
  end

  defp start_bot do
    id = "bot-#{System.unique_integer([:positive])}"

    start_supervised!(
      {Bot,
       id: id,
       session_id: "test-session",
       bot_username: "#{id}_username",
       bot_user_id: 1,
       owner_user_id: 1}
    )
  end
end
