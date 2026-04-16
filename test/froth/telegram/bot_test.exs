defmodule Froth.Telegram.BotTest do
  use ExUnit.Case, async: false

  alias Froth.Agent.Cycle
  alias Froth.Agent.ToolUse
  alias Froth.Repo
  alias Froth.Telegram.Bot

  setup do
    if is_nil(Process.whereis(Froth.Telegram.Registry)) do
      start_supervised!({Registry, keys: :unique, name: Froth.Telegram.Registry})
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    :ok
  end

  test "struct includes mid-cycle message buffer" do
    assert %Bot{mid_cycle_messages: []} = %Bot{}
  end

  test "commit_tool tracks narration message state" do
    bot = start_bot()
    tool_use = %ToolUse{id: "call_1", name: "run_shell", input: %{"command" => "pwd"}}
    context = %{cycle_id: "cycle_1", chat_id: 123, reply_to: 456}

    assert {:ok, "ok"} =
             GenServer.call(
               bot,
               {:commit_tool, tool_use, context, %{execution: %{cycle_id: "cycle_1"}},
                %{
                  result: {:ok, "ok"},
                  narration_message: %{message_id: 77, text: "Checking X", mode: :italic}
                }}
             )

    state = :sys.get_state(bot)
    assert state.current_narration_message_id == 77
    assert state.current_narration_text == "Checking X"
    assert state.current_narration_mode == :italic
  end

  test "commit_tool clears active narration when a normal message is sent" do
    bot = start_bot()
    tool_use = %ToolUse{id: "call_1", name: "send_message", input: %{"text" => "hello"}}
    context = %{cycle_id: "cycle_1", chat_id: 123, reply_to: 456}

    :sys.replace_state(bot, fn state ->
      %{
        state
        | current_narration_message_id: 77,
          current_narration_text: "Checking X\nAlso checking Y",
          current_narration_mode: :italic
      }
    end)

    outcome = %{
      result: {:ok, "sent"},
      sent_message: %{
        sent: %{"id" => 42},
        text: "hello"
      }
    }

    assert {:ok, "sent"} =
             GenServer.call(
               bot,
               {:commit_tool, tool_use, context, %{execution: %{cycle_id: "cycle_1"}}, outcome}
             )

    state = :sys.get_state(bot)
    assert state.last_sent_message_id == 42
    assert state.current_narration_message_id == nil
    assert state.current_narration_text == nil
    assert state.current_narration_mode == nil
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

  test "send-succeeded updates replace tracked temporary ids" do
    bot = start_bot()

    :sys.replace_state(bot, fn state ->
      %{
        state
        | last_sent_message_id: 101,
          current_narration_message_id: 202,
          current_narration_text: "Checking X",
          current_narration_mode: :italic
      }
    end)

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateMessageSendSucceeded",
         "old_message_id" => 202,
         "message" => %{"id" => 303}
       }}
    )

    assert :sys.get_state(bot).current_narration_message_id == 303
    assert :sys.get_state(bot).last_sent_message_id == 101

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateMessageSendSucceeded",
         "old_message_id" => 101,
         "message" => %{"id" => 404}
       }}
    )

    state = :sys.get_state(bot)
    assert state.last_sent_message_id == 404
    assert state.current_narration_message_id == 303
  end

  test "cycle footer edits the final message with cache stats when a cycle finishes" do
    test_pid = self()
    session_id = "test-session-#{System.unique_integer([:positive])}"
    bot = start_bot(session_id: session_id)

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: session_id, test_pid: test_pid}
    )

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

    worker_pid = start_supervised!({Agent, fn -> :ok end})
    worker_ref = make_ref()

    :sys.replace_state(bot, fn state ->
      %{
        state
        | cycle: cycle,
          worker_pid: worker_pid,
          worker_ref: worker_ref,
          chat_id: 123,
          last_sent_message_id: 42,
          last_sent_message_text: "hello"
      }
    end)

    send(bot, {:DOWN, worker_ref, :process, worker_pid, :normal})

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

  defp start_bot(opts \\ []) do
    id = "bot-#{System.unique_integer([:positive])}"
    session_id = Keyword.get(opts, :session_id, "test-session")

    start_supervised!(
      {Bot,
       id: id,
       session_id: session_id,
       bot_username: "#{id}_username",
       bot_user_id: 1,
       owner_user_id: 1}
    )
  end

  defmodule FakeTelegramSession do
    use GenServer

    def start_link(opts) when is_list(opts) do
      session_id = Keyword.fetch!(opts, :session_id)
      GenServer.start_link(__MODULE__, opts, name: Froth.Telegram.Session.via(session_id))
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid)
       }}
    end

    @impl true
    def handle_call({:call, request}, _from, state) do
      send(state.test_pid, {:telegram_call, request})
      {:reply, {:ok, %{}}, state}
    end

    @impl true
    def handle_cast({:send, request}, state) do
      send(state.test_pid, {:telegram_send, request})
      {:noreply, state}
    end
  end
end
