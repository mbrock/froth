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

    counter =
      start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> 0 end]}})

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
         model: "claude-opus-4-6",
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

    waiting_state = :sys.get_state(bot)
    assert is_pid(waiting_state.cycle_state.worker_pid)
    waiting_worker_pid = waiting_state.cycle_state.worker_pid

    assert waiting_state.cycle_state.awaiting_user_input? == true

    waiting_messages = cycle_messages(waiting_state.cycle_state.cycle.id)

    assert [{:user, first_waiting_user_text}, {:agent, nil}] =
             Enum.map(waiting_messages, &{&1.role, Message.extract_text(&1)})

    assert first_waiting_user_text =~ "help"

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

    assert :sys.get_state(bot).cycle_state.worker_pid == waiting_worker_pid

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

    assert_bot_idle(bot)
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

    counter =
      start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> 0 end]}})

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
         model: "claude-opus-4-6",
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

    assert_bot_idle(bot)
  end

  test "a parallel ask batch stays atomic and resumes on the same worker" do
    test_pid = self()
    bot_id = "charlie-ask-flow-parallel"
    session_id = "ask-flow-parallel-session"
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
                 "id" => "toolu_parallel_send_1",
                 "name" => "send_message",
                 "input" => %{"text" => "Working on it."}
               },
               %{
                 "type" => "tool_use",
                 "id" => "toolu_parallel_ask_1",
                 "name" => "ask",
                 "input" => %{
                   "question" => "Choose a lane.",
                   "alternatives" => ["Left", "Right"]
                 }
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_parallel_1"
           }}

        1 ->
          {:ok,
           %{
             text: "Done.",
             content: [%{"type" => "text", "text" => "Done."}],
             stop_reason: "end_turn",
             usage: %{},
             model: opts[:model],
             message_id: "msg_parallel_2"
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
         model: "claude-opus-4-6",
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

    assert_receive {:llm_call, 0, _messages, _opts}, 5_000

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Working on it."}}
                    }},
                   5_000

    assert_receive {:message_send_succeeded, _temp_id, _visible_message_id, ^chat_id}, 5_000

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Choose a lane."}}
                    }},
                   5_000

    assert_receive {:message_send_succeeded, _temp_id, prompt_message_id, ^chat_id}, 5_000
    assert_pending_ask_message_id(prompt_message_id)

    waiting_state = :sys.get_state(bot)
    assert is_pid(waiting_state.cycle_state.worker_pid)
    waiting_worker_pid = waiting_state.cycle_state.worker_pid

    waiting_messages = cycle_messages(waiting_state.cycle_state.cycle.id)

    assert [{:user, first_waiting_user_text}, {:agent, nil}] =
             Enum.map(waiting_messages, &{&1.role, Message.extract_text(&1)})

    assert first_waiting_user_text =~ "help"

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
           "content" => %{"text" => %{"text" => "Right"}}
         }
       }}
    )

    assert_receive {:llm_call, 1, resumed_messages, _opts}, 5_000
    assert :sys.get_state(bot).cycle_state.worker_pid == waiting_worker_pid

    last_message = List.last(resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_parallel_send_1",
               "content" => "sent"
             },
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_parallel_ask_1",
               "content" => "Right"
             }
           ] = last_message.content

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Done."}}
                    }},
                   5_000

    assert_bot_idle(bot)
  end

  test "await pauses the live worker with button choices and resumes in place" do
    test_pid = self()
    bot_id = "charlie-await-flow"
    session_id = "await-flow-session"
    chat_id = 362_441_422
    previous_fun = Application.get_env(:froth, :llm_stream_single_fun)
    {:ok, task_holder} = Agent.start_link(fn -> nil end)

    on_exit(fn ->
      if previous_fun do
        Application.put_env(:froth, :llm_stream_single_fun, previous_fun)
      else
        Application.delete_env(:froth, :llm_stream_single_fun)
      end

      task_id =
        try do
          Agent.get(task_holder, & &1)
        catch
          :exit, _reason -> nil
        end

      if is_binary(task_id) and Froth.Tasks.Shell.alive?(task_id) do
        Froth.Tasks.Shell.send_signal(task_id, "TERM")
      end
    end)

    counter =
      start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> 0 end]}})

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
                 "id" => "toolu_await_shell_1",
                 "name" => "run_shell",
                 "input" => %{
                   "command" => "sleep 30",
                   "description" => %{
                     "action" => "Starting a long-running shell task",
                     "goals" => ["Start the task", "Observe it in the background"],
                     "assumptions" => ["The command should stay alive past the inline wait"]
                   }
                 }
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_await_1"
           }}

        1 ->
          {:ok,
           %{
             text: "",
             content: [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_await_wait_1",
                 "name" => "await",
                 "input" => %{"reason" => "The shell task is still running."}
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_await_2"
           }}

        2 ->
          {:ok,
           %{
             text: "Still working.",
             content: [%{"type" => "text", "text" => "Still working."}],
             stop_reason: "end_turn",
             usage: %{},
             model: opts[:model],
             message_id: "msg_await_3"
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
         model: "claude-opus-4-6",
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

    assert_receive {:llm_call, 0, _messages, _opts}, 5_000
    assert_receive {:llm_call, 1, shell_resumed_messages, _opts}, 8_000

    shell_result_message = List.last(shell_resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_await_shell_1",
               "content" => shell_result
             }
           ] = shell_result_message.content

    [task_id] =
      Regex.run(~r/Started shell task ([a-z]+:[a-zA-Z0-9:_-]+)/, shell_result,
        capture: :all_but_first
      )

    Agent.update(task_holder, fn _ -> task_id end)

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "text" => %{"text" => "Awaiting background work" <> _ = await_text}
                      },
                      "reply_markup" => %{"@type" => "replyMarkupInlineKeyboard", "rows" => rows}
                    }},
                   8_000

    assert await_text =~ task_id
    assert get_in(rows, [Access.at(0), Access.at(0), "text"]) == "⛓️‍💥"
    assert get_in(rows, [Access.at(0), Access.at(1), "text"]) == "🏃‍➡️"
    assert get_in(rows, [Access.at(0), Access.at(2), "text"]) == "⏹️"
    assert get_in(rows, [Access.at(0), Access.at(3), "text"]) == "🧐"

    assert_receive {:message_send_succeeded, _temp_id, _await_message_id, ^chat_id}, 5_000
    await_pending_ask = fetch_pending_ask_by_question("Awaiting background work")
    await_message_id = await_pending_ask.message_id

    waiting_state = :sys.get_state(bot)
    assert is_pid(waiting_state.cycle_state.worker_pid)
    waiting_worker_pid = waiting_state.cycle_state.worker_pid

    assert MapSet.member?(
             Map.get(waiting_state.active_tasks, waiting_state.cycle_state.cycle.id, MapSet.new()),
             task_id
           )

    callback_query_id = "3234567890123456789"

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateNewCallbackQuery",
         "id" => callback_query_id,
         "chat_id" => chat_id,
         "message_id" => await_message_id,
         "sender_user_id" => 777,
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

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "chat_id" => ^chat_id,
                      "message_id" => edited_message_id,
                      "input_message_content" => %{"text" => %{"text" => edited_await_text}}
                    }},
                   5_000

    assert is_integer(edited_message_id)
    assert edited_await_text =~ "→ Continued while waiting"

    assert_receive {:llm_call, 2, resumed_messages, _opts}, 5_000
    assert :sys.get_state(bot).cycle_state.worker_pid == waiting_worker_pid

    last_message = List.last(resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_await_wait_1",
               "content" => await_resolution
             }
           ] = last_message.content

    assert await_resolution =~ "keep working while the background tasks continue"
    assert await_resolution =~ task_id

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Still working."}}
                    }},
                   5_000

    assert_bot_idle(bot)
  end

  test "failure intervention posts a report, edits it after a callback choice, and resumes with the injected report" do
    test_pid = self()
    bot_id = "charlie-failure-flow-callback"
    session_id = "failure-flow-callback-session"
    chat_id = 362_441_422
    previous_fun = Application.get_env(:froth, :llm_stream_single_fun)

    on_exit(fn ->
      if previous_fun do
        Application.put_env(:froth, :llm_stream_single_fun, previous_fun)
      else
        Application.delete_env(:froth, :llm_stream_single_fun)
      end
    end)

    main_counter = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
      tool_names = Enum.map(opts[:tools] || [], & &1["name"])
      send(test_pid, {:llm_call, tool_names, api_messages, opts})

      case tool_names do
        ["deliver_failure_report"] ->
          {:ok,
           %{
             text: "",
             content: [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_failure_report_1",
                 "name" => "deliver_failure_report",
                 "input" => %{
                   "intention" => "Inspect the current directory.",
                   "situation" => "The agent tried one shell command and it failed immediately.",
                   "invocation" => "run_shell command=\"false\"",
                   "expectation" => "The shell command would succeed.",
                   "irritation" => "The shell returned \"exit code: 1\".",
                   "designation" => "minor shell stumble",
                   "intervention" => [
                     "Check the working directory before retrying.",
                     "Run pwd and then retry with the exact path."
                   ]
                 }
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_failure_report_1"
           }}

        _ ->
          call =
            Agent.get_and_update(main_counter, fn current ->
              {current, current + 1}
            end)

          case call do
            0 ->
              {:ok,
               %{
                 text: "",
                 content: [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_failure_1",
                     "name" => "run_shell",
                     "input" => %{"command" => "false"}
                   }
                 ],
                 stop_reason: "tool_use",
                 usage: %{},
                 model: opts[:model],
                 message_id: "msg_failure_1"
               }}

            1 ->
              {:ok,
               %{
                 text: "Settled.",
                 content: [%{"type" => "text", "text" => "Settled."}],
                 stop_reason: "end_turn",
                 usage: %{},
                 model: opts[:model],
                 message_id: "msg_failure_2"
               }}
          end
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
         model: "claude-opus-4-6",
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

    assert_receive {:llm_call, tool_names, _api_messages, _opts}, 5_000
    assert "run_shell" in tool_names
    assert_receive {:llm_call, ["deliver_failure_report"], report_messages, report_opts}, 5_000
    assert report_opts[:model] == "gpt-5.4-mini"
    assert [%Froth.LLM.Message{role: :user}] = report_messages

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "text" => %{"text" => report_text}
                      },
                      "reply_markup" => %{"@type" => "replyMarkupInlineKeyboard", "rows" => rows}
                    }},
                   5_000

    assert report_text =~ "Failure intervention"
    assert report_text =~ "minor shell stumble"
    assert get_in(rows, [Access.at(0), Access.at(0), "text"]) == "1️⃣"
    assert get_in(rows, [Access.at(0), Access.at(1), "text"]) == "2️⃣"
    assert get_in(rows, [Access.at(1), Access.at(0), "text"]) == "🤘"
    assert get_in(rows, [Access.at(1), Access.at(1), "text"]) == "🔍"
    assert get_in(rows, [Access.at(1), Access.at(2), "text"]) == "🙅"

    assert_receive {:message_send_succeeded, _temp_id, report_message_id, ^chat_id}, 5_000
    assert_pending_ask_message_id(report_message_id)

    callback_query_id = "2234567890123456789"

    send(
      bot,
      {:telegram_update,
       %{
         "@type" => "updateNewCallbackQuery",
         "id" => callback_query_id,
         "chat_id" => chat_id,
         "message_id" => report_message_id,
         "sender_user_id" => 777,
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

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "chat_id" => ^chat_id,
                      "message_id" => ^report_message_id,
                      "input_message_content" => %{
                        "text" => %{"text" => edited_report_text}
                      },
                      "reply_markup" => %{"@type" => "replyMarkupInlineKeyboard", "rows" => []}
                    }},
                   5_000

    assert edited_report_text =~ "→ Intervention #2 chosen"

    assert_receive {:llm_call, _tool_names, resumed_messages, _opts}, 5_000

    last_message = List.last(resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_failure_1",
               "content" => resumed_content,
               "is_error" => true
             }
           ] = last_message.content

    assert resumed_content =~ "Failure report"
    assert resumed_content =~ "Chosen intervention: Run pwd and then retry with the exact path."
    assert resumed_content =~ "Original error"
    assert resumed_content =~ "exit code: 1"

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Settled."}}
                    }},
                   5_000

    assert_bot_idle(bot)
  end

  test "failure intervention accepts a direct reply as a custom intervention" do
    test_pid = self()
    bot_id = "charlie-failure-flow-reply"
    session_id = "failure-flow-reply-session"
    chat_id = 362_441_422
    previous_fun = Application.get_env(:froth, :llm_stream_single_fun)

    on_exit(fn ->
      if previous_fun do
        Application.put_env(:froth, :llm_stream_single_fun, previous_fun)
      else
        Application.delete_env(:froth, :llm_stream_single_fun)
      end
    end)

    main_counter = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:froth, :llm_stream_single_fun, fn api_messages, _on_event, opts ->
      tool_names = Enum.map(opts[:tools] || [], & &1["name"])
      send(test_pid, {:llm_call, tool_names, api_messages, opts})

      case tool_names do
        ["deliver_failure_report"] ->
          {:ok,
           %{
             text: "",
             content: [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_failure_report_2",
                 "name" => "deliver_failure_report",
                 "input" => %{
                   "intention" => "Run a shell command.",
                   "situation" =>
                     "The first shell command failed and the cycle stopped for review.",
                   "invocation" => "run_shell command=\"false\"",
                   "expectation" => "The shell command would succeed.",
                   "irritation" => "The shell returned \"exit code: 1\".",
                   "designation" => "shell derailment",
                   "intervention" => ["Check the cwd before retrying."]
                 }
               }
             ],
             stop_reason: "tool_use",
             usage: %{},
             model: opts[:model],
             message_id: "msg_failure_report_2"
           }}

        _ ->
          call =
            Agent.get_and_update(main_counter, fn current ->
              {current, current + 1}
            end)

          case call do
            0 ->
              {:ok,
               %{
                 text: "",
                 content: [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_failure_reply_1",
                     "name" => "run_shell",
                     "input" => %{"command" => "false"}
                   }
                 ],
                 stop_reason: "tool_use",
                 usage: %{},
                 model: opts[:model],
                 message_id: "msg_failure_reply_1"
               }}

            1 ->
              {:ok,
               %{
                 text: "Fixed.",
                 content: [%{"type" => "text", "text" => "Fixed."}],
                 stop_reason: "end_turn",
                 usage: %{},
                 model: opts[:model],
                 message_id: "msg_failure_reply_2"
               }}
          end
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
         model: "claude-opus-4-6",
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

    assert_receive {:llm_call, tool_names, _api_messages, _opts}, 5_000
    assert "run_shell" in tool_names
    assert_receive {:llm_call, ["deliver_failure_report"], _report_messages, _report_opts}, 5_000

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => report_text}}
                    }},
                   5_000

    assert report_text =~ "Failure intervention"

    assert_receive {:message_send_succeeded, _temp_id, report_message_id, ^chat_id}, 5_000
    assert_pending_ask_message_id(report_message_id)

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
             "message_id" => report_message_id,
             "chat_id" => chat_id
           },
           "content" => %{
             "text" => %{"text" => "Run pwd first and only retry if the cwd is right."}
           }
         }
       }}
    )

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "chat_id" => ^chat_id,
                      "message_id" => ^report_message_id,
                      "input_message_content" => %{
                        "text" => %{"text" => edited_report_text}
                      }
                    }},
                   5_000

    assert edited_report_text =~ "→ Custom intervention recorded"

    assert_receive {:llm_call, _tool_names, resumed_messages, _opts}, 5_000

    last_message = List.last(resumed_messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_failure_reply_1",
               "content" => resumed_content,
               "is_error" => true
             }
           ] = last_message.content

    assert resumed_content =~ "Failure report"
    assert resumed_content =~ "Custom intervention from user:777"
    assert resumed_content =~ "Run pwd first and only retry if the cwd is right."

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Fixed."}}
                    }},
                   5_000

    assert_bot_idle(bot)
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

  defp fetch_pending_ask_by_question(question_prefix, attempts \\ 300)

  defp fetch_pending_ask_by_question(question_prefix, attempts)
       when is_binary(question_prefix) and attempts > 0 do
    query =
      from(p in PendingAsk,
        where: like(p.question, ^"#{question_prefix}%"),
        limit: 1
      )

    case Repo.one(query, log: false) do
      %PendingAsk{} = pending_ask
      when is_integer(pending_ask.message_id) and pending_ask.message_id >= 10_000 ->
        pending_ask

      _other ->
        receive do
        after
          20 -> fetch_pending_ask_by_question(question_prefix, attempts - 1)
        end
    end
  end

  defp fetch_pending_ask_by_question(question_prefix, 0) do
    flunk("pending ask did not appear for question #{inspect(question_prefix)}")
  end

  defp cycle_messages(cycle_id) do
    Froth.Repo.get!(Froth.Agent.Cycle, cycle_id)
    |> Froth.Agent.latest_head_id()
    |> Froth.Agent.load_messages()
  end

  defp assert_bot_idle(bot, attempts \\ 200)

  defp assert_bot_idle(bot, attempts) when is_pid(bot) and attempts > 0 do
    case :sys.get_state(bot) do
      %{cycle_state: nil, pending_ask_resumes: []} ->
        :ok

      _state ->
        receive do
        after
          20 -> assert_bot_idle(bot, attempts - 1)
        end
    end
  end

  defp assert_bot_idle(_bot, 0) do
    flunk("bot did not become idle in time")
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
