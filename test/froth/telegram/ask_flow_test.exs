defmodule Froth.Telegram.AskFlowTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Froth.Agent.Message
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.Repo
  alias Froth.Telegram.Bot
  alias Froth.Telegram.PendingAsk

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    if is_nil(Process.whereis(Froth.Telegram.Registry)) do
      start_supervised!({Registry, keys: :unique, name: Froth.Telegram.Registry})
    end

    :ok
  end

  test "ask pauses a cycle, waits for a free-form answer, and resumes with a real tool result" do
    test_pid = self()
    bot_id = "charlie-ask-flow-freeform"
    session_id = "ask-flow-session"
    chat_id = 362_441_422
    previous_fun = Application.get_env(:froth, :llm_stream_single_fun)

    on_exit(fn ->
      if previous_fun do
        Application.put_env(:froth, :llm_stream_single_fun, previous_fun)
      else
        Application.delete_env(:froth, :llm_stream_single_fun)
      end
    end)

    counter = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
      call =
        Agent.get_and_update(counter, fn current ->
          {current, current + 1}
        end)

      send(test_pid, {:llm_call, call, api_messages, opts})

      case call do
        0 ->
          {:ok,
           %{
             text: "",
             content: [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_ask_flow_1",
                 "name" => "ask",
                 "input" => %{
                   "question" => "Which option do you want?",
                   "alternatives" => ["Alpha", "Beta"]
                 }
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_ask_flow_1"
           }}

        1 ->
          {:ok,
           %{
             text: "Settled.",
             content: [%{"type" => "text", "text" => "Settled."}],
             stop_reason: "end_turn",
             usage: %{},
             model: opts[:model],
             message_id: "msg_ask_flow_2"
           }}
      end
    end)

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: session_id, test_pid: test_pid}
    )

    bot =
      start_supervised!(
        {Bot,
         id: bot_id,
         session_id: session_id,
         bot_username: "charliebuddybot",
         bot_user_id: 1,
         owner_user_id: 1,
         system_prompt: "You are Charlie.",
         debounce_ms: 0,
         tools_module: Froth.Telegram.Toolsets.Charlie}
      )

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateNewMessage",
         "message" => %{
           "id" => 10,
           "chat_id" => chat_id,
           "sender_id" => %{"user_id" => 777},
           "content" => %{"text" => %{"text" => "help"}}
         }
       }}
    )

    assert_receive {:llm_call, 0, api_messages, _opts}, 5_000
    assert [%LLMMessage{role: :user}] = api_messages

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "text" => %{"text" => "Which option do you want?"}
                      },
                      "reply_markup" => %{"@type" => "replyMarkupInlineKeyboard"}
                    }},
                   5_000

    assert_receive {:message_send_succeeded, _temp_id, prompt_message_id, ^chat_id}, 5_000
    assert_pending_ask_message_id(prompt_message_id)

    refute_receive {:telegram_call, %{"@type" => "sendMessage"}}, 200

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateNewMessage",
         "message" => %{
           "id" => 11,
           "chat_id" => chat_id,
           "sender_id" => %{"user_id" => 777},
           "reply_to" => %{
             "@type" => "messageReplyToMessage",
             "message_id" => prompt_message_id,
             "chat_id" => chat_id
           },
           "content" => %{"text" => %{"text" => "Beta"}}
         }
       }}
    )

    assert_receive {:llm_call, 1, resumed_messages, _opts}, 5_000

    assert [%LLMMessage{role: :user}, %LLMMessage{role: :assistant}, %LLMMessage{role: :user}] =
             resumed_messages

    last_message = List.last(resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_ask_flow_1",
               "content" => "Beta"
             }
           ] = last_message.content

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Settled."}}
                    }},
                   5_000

    pending_ask = Repo.one!(from(p in PendingAsk, limit: 1))
    assert pending_ask.answer == "Beta"
    assert pending_ask.answer_message_id == 11
    assert pending_ask.answered_via == "message"
    assert pending_ask.resolved_at

    messages =
      pending_ask.cycle_id
      |> cycle_messages()
      |> Enum.map(&{&1.role, Message.extract_text(&1)})

    assert {:user, first_user_text} = Enum.at(messages, 0)
    assert first_user_text =~ "help"
    assert Enum.at(messages, 1) == {:agent, nil}
    assert Enum.at(messages, 2) == {:user, nil}
    assert Enum.at(messages, 3) == {:agent, "Settled."}
  end

  test "ask resumes when an inline callback query uses a TDLib string id" do
    test_pid = self()
    bot_id = "charlie-ask-flow-callback"
    session_id = "ask-callback-session"
    chat_id = 362_441_422
    previous_fun = Application.get_env(:froth, :llm_stream_single_fun)

    on_exit(fn ->
      if previous_fun do
        Application.put_env(:froth, :llm_stream_single_fun, previous_fun)
      else
        Application.delete_env(:froth, :llm_stream_single_fun)
      end
    end)

    counter = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
      call =
        Agent.get_and_update(counter, fn current ->
          {current, current + 1}
        end)

      send(test_pid, {:llm_call, call, api_messages, opts})

      case call do
        0 ->
          {:ok,
           %{
             text: "",
             content: [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_ask_flow_callback_1",
                 "name" => "ask",
                 "input" => %{
                   "question" => "Which option do you want?",
                   "alternatives" => ["Alpha", "Beta"]
                 }
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_ask_flow_callback_1"
           }}

        1 ->
          {:ok,
           %{
             text: "Settled.",
             content: [%{"type" => "text", "text" => "Settled."}],
             stop_reason: "end_turn",
             usage: %{},
             model: opts[:model],
             message_id: "msg_ask_flow_callback_2"
           }}
      end
    end)

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: session_id, test_pid: test_pid}
    )

    bot =
      start_supervised!(
        {Bot,
         id: bot_id,
         session_id: session_id,
         bot_username: "charliebuddybot",
         bot_user_id: 1,
         owner_user_id: 1,
         system_prompt: "You are Charlie.",
         debounce_ms: 0,
         tools_module: Froth.Telegram.Toolsets.Charlie}
      )

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateNewMessage",
         "message" => %{
           "id" => 10,
           "chat_id" => chat_id,
           "sender_id" => %{"user_id" => 777},
           "content" => %{"text" => %{"text" => "help"}}
         }
       }}
    )

    assert_receive {:llm_call, 0, api_messages, _opts}, 5_000
    assert [%LLMMessage{role: :user}] = api_messages

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "text" => %{"text" => "Which option do you want?"}
                      },
                      "reply_markup" => %{"@type" => "replyMarkupInlineKeyboard"}
                    }},
                   5_000

    assert_receive {:message_send_succeeded, _temp_id, prompt_message_id, ^chat_id}, 5_000
    assert_pending_ask_message_id(prompt_message_id)

    callback_query_id = "1234567890123456789"

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateNewCallbackQuery",
         "id" => callback_query_id,
         "chat_id" => chat_id,
         "message_id" => prompt_message_id,
         "payload" => %{
           "@type" => "callbackQueryPayloadData",
           "data" => Base.encode64("ask:1")
         }
       }}
    )

    assert_receive {:telegram_send,
                    %{
                      "@type" => "answerCallbackQuery",
                      "callback_query_id" => ^callback_query_id
                    }},
                   5_000

    assert_receive {:llm_call, 1, resumed_messages, _opts}, 5_000

    assert [%LLMMessage{role: :user}, %LLMMessage{role: :assistant}, %LLMMessage{role: :user}] =
             resumed_messages

    last_message = List.last(resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_ask_flow_callback_1",
               "content" => "Beta"
             }
           ] = last_message.content

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Settled."}}
                    }},
                   5_000

    pending_ask = Repo.one!(from(p in PendingAsk, limit: 1))
    assert pending_ask.answer == "Beta"
    assert pending_ask.answer_message_id == nil
    assert pending_ask.answered_via == "callback"
    assert pending_ask.resolved_at
  end

  defp assert_pending_ask_message_id(message_id, attempts \\ 300)

  defp assert_pending_ask_message_id(message_id, attempts)
       when is_integer(message_id) and attempts > 0 do
    case Repo.one(from(p in PendingAsk, select: p.message_id, limit: 1), log: false) do
      ^message_id ->
        :ok

      _other ->
        receive do
        after
          20 -> assert_pending_ask_message_id(message_id, attempts - 1)
        end
    end
  end

  defp assert_pending_ask_message_id(message_id, 0) do
    flunk("pending ask did not sync to message_id #{message_id}")
  end

  defp cycle_messages(cycle_id) do
    Froth.Repo.get!(Froth.Agent.Cycle, cycle_id)
    |> Froth.Agent.latest_head_id()
    |> Froth.Agent.load_messages()
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
         session_id: Keyword.fetch!(opts, :session_id),
         test_pid: Keyword.fetch!(opts, :test_pid),
         next_temp_id: 1_000
       }}
    end

    @impl true
    def handle_call({:call, request}, _from, state) do
      send(state.test_pid, {:telegram_call, request})

      case request["@type"] do
        "sendMessage" ->
          temp_id = state.next_temp_id
          final_id = temp_id + 10_000
          chat_id = request["chat_id"]
          send(self(), {:send_success, temp_id, final_id, chat_id})

          {:reply, {:ok, %{"id" => temp_id, "chat_id" => chat_id}},
           %{state | next_temp_id: temp_id + 1}}

        "answerCallbackQuery" ->
          {:reply, {:ok, %{}}, state}

        "editMessageText" ->
          {:reply, {:ok, %{}}, state}

        "parseTextEntities" ->
          {:reply,
           {:ok, %{"@type" => "formattedText", "text" => request["text"], "entities" => []}},
           state}

        _ ->
          {:reply, {:ok, %{}}, state}
      end
    end

    @impl true
    def handle_cast({:send, request}, state) do
      send(state.test_pid, {:telegram_send, request})
      {:noreply, state}
    end

    @impl true
    def handle_info({:send_success, old_id, new_id, chat_id}, state) do
      Phoenix.PubSub.broadcast(
        Froth.PubSub,
        Froth.Telegram.Session.topic(state.session_id),
        {:telegram_update,
         %{
           "@type" => "updateMessageSendSucceeded",
           "old_message_id" => old_id,
           "message" => %{"id" => new_id, "chat_id" => chat_id}
         }}
      )

      send(state.test_pid, {:message_send_succeeded, old_id, new_id, chat_id})
      {:noreply, state}
    end
  end
end
