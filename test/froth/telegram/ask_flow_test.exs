defmodule Froth.Telegram.AskFlowTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Froth.Agent.Message
  alias Froth.LLM.Fake, as: FakeLLM
  alias Froth.LLM.Message, as: LLMMessage
  alias Froth.LLM.Request
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
    chat_id = 362_441_422
    model = FakeLLM.claim()

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: "ask-flow-session", test_pid: self()}
    )

    bot = start_charlie_bot(id: "charlie-ask-flow-freeform", session_id: "ask-flow-session", model: model)

    send(bot, user_update("help", message_id: 10, chat_id: chat_id))

    # Turn 1: initial user message -> LLM emits the `ask` tool_use.
    assert_receive {FakeLLM, turn_1, %Request{} = request_1}, 5_000
    assert [%LLMMessage{role: :user}] = request_1.messages

    FakeLLM.reply(
      turn_1,
      {:ok, tool_use_response("toolu_ask_flow_1", "ask", %{
         "question" => "Which option do you want?",
         "alternatives" => ["Alpha", "Beta"]
       })}
    )

    # Bot posts the ask prompt with inline buttons.
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
    assert is_pid(waiting_state.cycle_state.cycle_runtime_pid)
    waiting_runtime_pid = waiting_state.cycle_state.cycle_runtime_pid

    assert :sys.get_state(waiting_state.cycle_state.cycle_runtime_pid).context.view.awaiting_user_input? ==
             true

    waiting_messages = cycle_messages(waiting_state.cycle_state.cycle_id)

    assert [{:user, first_waiting_user_text}, {:agent, nil}] =
             Enum.map(waiting_messages, &{&1.role, Message.extract_text(&1)})

    assert first_waiting_user_text =~ "help"

    refute_receive {:telegram_call, %{"@type" => "sendMessage"}}, 200

    # User replies "Beta" to the ask prompt.
    send(
      bot,
      user_reply_update("Beta",
        message_id: 11,
        reply_to_message_id: prompt_message_id,
        chat_id: chat_id
      )
    )

    # Turn 2: the cycle resumes with tool_result "Beta" and the LLM ends the turn.
    assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5_000

    assert [%LLMMessage{role: :user}, %LLMMessage{role: :assistant}, %LLMMessage{role: :user}] =
             request_2.messages

    last_message = List.last(request_2.messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_ask_flow_1",
               "content" => "Beta"
             }
           ] = last_message.content

    assert :sys.get_state(bot).cycle_state.cycle_runtime_pid == waiting_runtime_pid

    FakeLLM.reply(turn_2, {:ok, text_response("Settled.")})

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
    chat_id = 362_441_422
    model = FakeLLM.claim()

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: "ask-callback-session", test_pid: self()}
    )

    bot =
      start_charlie_bot(
        id: "charlie-ask-flow-callback",
        session_id: "ask-callback-session",
        model: model
      )

    send(bot, user_update("help", message_id: 10, chat_id: chat_id))

    assert_receive {FakeLLM, turn_1, %Request{messages: [%LLMMessage{role: :user}]}}, 5_000

    FakeLLM.reply(
      turn_1,
      {:ok, tool_use_response("toolu_ask_flow_callback_1", "ask", %{
         "question" => "Which option do you want?",
         "alternatives" => ["Alpha", "Beta"]
       })}
    )

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

    assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5_000

    assert [%LLMMessage{role: :user}, %LLMMessage{role: :assistant}, %LLMMessage{role: :user}] =
             request_2.messages

    last_message = List.last(request_2.messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_ask_flow_callback_1",
               "content" => "Beta"
             }
           ] = last_message.content

    FakeLLM.reply(turn_2, {:ok, text_response("Settled.")})

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
    chat_id = 362_441_422
    model = FakeLLM.claim()

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: "ask-flow-parallel-session", test_pid: self()}
    )

    bot =
      start_charlie_bot(
        id: "charlie-ask-flow-parallel",
        session_id: "ask-flow-parallel-session",
        model: model
      )

    send(bot, user_update("help", message_id: 10, chat_id: chat_id))

    # Turn 1: the LLM emits BOTH a send_message and an ask in one assistant turn.
    assert_receive {FakeLLM, turn_1, %Request{}}, 5_000

    FakeLLM.reply(
      turn_1,
      {:ok,
       %{
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
         stop_reason: "tool_use"
       }}
    )

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
    assert is_pid(waiting_state.cycle_state.cycle_runtime_pid)
    waiting_runtime_pid = waiting_state.cycle_state.cycle_runtime_pid

    waiting_messages = cycle_messages(waiting_state.cycle_state.cycle_id)

    assert [{:user, first_waiting_user_text}, {:agent, nil}] =
             Enum.map(waiting_messages, &{&1.role, Message.extract_text(&1)})

    assert first_waiting_user_text =~ "help"

    send(
      bot,
      user_reply_update("Right",
        message_id: 11,
        reply_to_message_id: prompt_message_id,
        chat_id: chat_id
      )
    )

    # Turn 2: the resumed request carries BOTH tool_results atomically.
    assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 5_000
    assert :sys.get_state(bot).cycle_state.cycle_runtime_pid == waiting_runtime_pid

    last_message = List.last(request_2.messages)

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

    FakeLLM.reply(turn_2, {:ok, text_response("Done.")})

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
    chat_id = 362_441_422
    model = FakeLLM.claim()
    {:ok, task_holder} = Agent.start_link(fn -> nil end)

    on_exit(fn ->
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

    start_supervised!(
      {__MODULE__.FakeTelegramSession, session_id: "await-flow-session", test_pid: self()}
    )

    bot =
      start_charlie_bot(
        id: "charlie-await-flow",
        session_id: "await-flow-session",
        model: model
      )

    send(bot, user_update("help", message_id: 10, chat_id: chat_id))

    # Turn 1: kick off a long-running shell task.
    assert_receive {FakeLLM, turn_1, %Request{}}, 5_000

    FakeLLM.reply(
      turn_1,
      {:ok, tool_use_response("toolu_await_shell_1", "run_shell", %{
         "command" => "sleep 30",
         "description" => %{
           "action" => "Starting a long-running shell task",
           "goals" => ["Start the task", "Observe it in the background"],
           "assumptions" => ["The command should stay alive past the inline wait"]
         }
       })}
    )

    # Turn 2: after run_shell returns a task id, the LLM calls `await`.
    assert_receive {FakeLLM, turn_2, %Request{} = request_2}, 8_000

    shell_result_message = List.last(request_2.messages)

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

    FakeLLM.reply(
      turn_2,
      {:ok, tool_use_response("toolu_await_wait_1", "await", %{
         "reason" => "The shell task is still running."
       })}
    )

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
    assert is_pid(waiting_state.cycle_state.cycle_runtime_pid)
    waiting_runtime_pid = waiting_state.cycle_state.cycle_runtime_pid

    assert task_id in Froth.Agent.CycleRuntime.active_task_ids(waiting_state.cycle_state.cycle_id)

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

    # Turn 3: the await resolves and the LLM ends the turn.
    assert_receive {FakeLLM, turn_3, %Request{} = request_3}, 5_000
    assert :sys.get_state(bot).cycle_state.cycle_runtime_pid == waiting_runtime_pid

    last_message = List.last(request_3.messages)

    assert [
             %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_await_wait_1",
               "content" => await_resolution
             }
           ] = last_message.content

    assert await_resolution =~ "keep working while the background tasks continue"
    assert await_resolution =~ task_id

    FakeLLM.reply(turn_3, {:ok, text_response("Still working.")})

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
    chat_id = 362_441_422
    main_model = FakeLLM.claim()
    report_model = FakeLLM.claim()

    start_supervised!(
      {__MODULE__.FakeTelegramSession,
       session_id: "failure-flow-callback-session", test_pid: self()}
    )

    bot =
      start_charlie_bot(
        id: "charlie-failure-flow-callback",
        session_id: "failure-flow-callback-session",
        model: main_model,
        failure_report_model: report_model
      )

    send(bot, user_update("help", message_id: 10, chat_id: chat_id))

    # Turn 1: the main LLM decides to run a failing shell command.
    assert_receive {FakeLLM, main_turn_1, %Request{} = main_request_1}, 5_000
    main_tool_names = Enum.map(main_request_1.tools, & &1["name"])
    assert "run_shell" in main_tool_names

    FakeLLM.reply(
      main_turn_1,
      {:ok, tool_use_response("toolu_failure_1", "run_shell", %{"command" => "false"})}
    )

    # The failure-report LLM gets asked to build a structured report.
    assert_receive {FakeLLM, report_turn, %Request{} = report_request}, 5_000
    assert report_request.model == report_model
    assert [%LLMMessage{role: :user}] = report_request.messages
    assert Enum.map(report_request.tools, & &1["name"]) == ["deliver_failure_report"]

    FakeLLM.reply(
      report_turn,
      {:ok, tool_use_response("toolu_failure_report_1", "deliver_failure_report", %{
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
       })}
    )

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

    # Turn 2: main cycle resumes with the injected failure report as the tool_result.
    assert_receive {FakeLLM, main_turn_2, %Request{} = main_request_2}, 5_000

    last_message = List.last(main_request_2.messages)

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

    FakeLLM.reply(main_turn_2, {:ok, text_response("Settled.")})

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
    chat_id = 362_441_422
    main_model = FakeLLM.claim()
    report_model = FakeLLM.claim()

    start_supervised!(
      {__MODULE__.FakeTelegramSession,
       session_id: "failure-flow-reply-session", test_pid: self()}
    )

    bot =
      start_charlie_bot(
        id: "charlie-failure-flow-reply",
        session_id: "failure-flow-reply-session",
        model: main_model,
        failure_report_model: report_model
      )

    send(bot, user_update("help", message_id: 10, chat_id: chat_id))

    assert_receive {FakeLLM, main_turn_1, %Request{} = main_request_1}, 5_000
    main_tool_names = Enum.map(main_request_1.tools, & &1["name"])
    assert "run_shell" in main_tool_names

    FakeLLM.reply(
      main_turn_1,
      {:ok, tool_use_response("toolu_failure_reply_1", "run_shell", %{"command" => "false"})}
    )

    assert_receive {FakeLLM, report_turn, %Request{} = report_request}, 5_000
    assert report_request.model == report_model

    FakeLLM.reply(
      report_turn,
      {:ok, tool_use_response("toolu_failure_report_2", "deliver_failure_report", %{
         "intention" => "Run a shell command.",
         "situation" => "The first shell command failed and the cycle stopped for review.",
         "invocation" => "run_shell command=\"false\"",
         "expectation" => "The shell command would succeed.",
         "irritation" => "The shell returned \"exit code: 1\".",
         "designation" => "shell derailment",
         "intervention" => ["Check the cwd before retrying."]
       })}
    )

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
      user_reply_update("Run pwd first and only retry if the cwd is right.",
        message_id: 11,
        reply_to_message_id: report_message_id,
        chat_id: chat_id
      )
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

    assert_receive {FakeLLM, main_turn_2, %Request{} = main_request_2}, 5_000

    last_message = List.last(main_request_2.messages)

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

    FakeLLM.reply(main_turn_2, {:ok, text_response("Fixed.")})

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{"text" => %{"text" => "Fixed."}}
                    }},
                   5_000

    assert_bot_idle(bot)
  end

  # -- test helpers --

  defp start_charlie_bot(opts) do
    defaults = [
      bot_username: "charliebuddybot",
      bot_user_id: 1,
      owner_user_id: 1,
      system_prompt: "You are Charlie.",
      debounce_ms: 0,
      tools_module: Froth.Telegram.Toolsets.Charlie
    ]

    start_supervised!({Bot, Keyword.merge(defaults, opts)})
  end

  defp tool_use_response(id, name, input) do
    %{
      content: [
        %{
          "type" => "tool_use",
          "id" => id,
          "name" => name,
          "input" => input
        }
      ],
      stop_reason: "tool_use"
    }
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

    {:telegram_update,
     %{
       "@type" => "updateNewMessage",
       "message" => %{
         "id" => message_id,
         "chat_id" => chat_id,
         "sender_id" => %{"user_id" => sender_user_id},
         "content" => %{"text" => %{"text" => text}}
       }
     }}
  end

  defp user_reply_update(text, opts) do
    chat_id = Keyword.get(opts, :chat_id, 362_441_422)
    message_id = Keyword.fetch!(opts, :message_id)
    reply_to_message_id = Keyword.fetch!(opts, :reply_to_message_id)
    sender_user_id = Keyword.get(opts, :sender_user_id, 777)

    {:telegram_update,
     %{
       "@type" => "updateNewMessage",
       "message" => %{
         "id" => message_id,
         "chat_id" => chat_id,
         "sender_id" => %{"user_id" => sender_user_id},
         "reply_to" => %{
           "@type" => "messageReplyToMessage",
           "message_id" => reply_to_message_id,
           "chat_id" => chat_id
         },
         "content" => %{"text" => %{"text" => text}}
       }
     }}
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
