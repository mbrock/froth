defmodule Froth.Agent.AdhocToolExecutorTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.{AdhocToolExecutor, ToolUse}

  test "run_shell prepares Telegram narration with a control prompt and inline buttons" do
    executor =
      start_supervised!(
        {AdhocToolExecutor,
         bot_id: "charlie",
         bot_username: "charliebuddybot",
         session_id: "charlie",
         chat_id: 123,
         reply_to: 456,
         prompt: "Inspect the agent workspace",
         model: "gpt-5.4-nano",
         provider: "openai"}
      )

    tool_use = %ToolUse{
      id: "call_1",
      name: "run_shell",
      input: %{
        "command" => "ls",
        "description" => %{
          "action" => "Listing agent directory contents",
          "goals" => [
            "see what files are present",
            "confirm the workspace shape",
            "avoid guessing about the directory contents"
          ],
          "assumptions" => ["the current directory is the intended workspace"]
        }
      }
    }

    assert {:ok, %{execution: execution}} =
             GenServer.call(executor, {:prepare_tool, tool_use, %{cycle_id: "cycle_1"}})

    assert execution.reply_to == 456
    assert execution.input["reply_to"] == 456
    assert execution.input["send_control_prompt"] == true
    refute Map.has_key?(execution.input["control_prompt"], "text")

    assert execution.input["control_prompt"]["markdown"] ==
             "*Running* gpt\\-5\\.4\\-nano \\(openai\\)\n\n*Prompt*\nInspect the agent workspace"

    assert execution.input["control_prompt"]["reply_markup"]["rows"] == [
             [
               %{
                 "@type" => "inlineKeyboardButton",
                 "text" => "Open",
                 "type" => %{
                   "@type" => "inlineKeyboardButtonTypeUrl",
                   "url" => "https://t.me/charliebuddybot/tool?startapp=cycle_charlie_cycle_1"
                 }
               },
               %{
                 "@type" => "inlineKeyboardButton",
                 "text" => "Stop",
                 "type" => %{
                   "@type" => "inlineKeyboardButtonTypeCallback",
                   "data" => Base.encode64("stopcycle:cycle_1")
                 }
               }
             ]
           ]
  end

  test "the first ordinary tool in a cycle also gets the control prompt" do
    executor =
      start_supervised!(
        {AdhocToolExecutor,
         bot_id: "charlie",
         bot_username: "charliebuddybot",
         session_id: "charlie",
         chat_id: 123,
         reply_to: 456,
         prompt: "Investigate the chat history",
         model: "gpt-5.4",
         provider: "openai"}
      )

    tool_use = %ToolUse{
      id: "call_1",
      name: "read_log",
      input: %{"from_date" => "2026-03-25"}
    }

    assert {:ok, %{execution: execution}} =
             GenServer.call(executor, {:prepare_tool, tool_use, %{cycle_id: "cycle_1"}})

    assert execution.input["send_control_prompt"] == true

    assert execution.input["control_prompt"]["markdown"] ==
             "*Running* gpt\\-5\\.4 \\(openai\\)\n\n*Prompt*\nInvestigate the chat history"
  end

  test "control prompt is reserved once per cycle and elixir_eval gets the cycle topic" do
    executor =
      start_supervised!(
        {AdhocToolExecutor,
         bot_id: "charlie",
         bot_username: "charliebuddybot",
         session_id: "charlie",
         chat_id: 123,
         reply_to: 456,
         prompt: "Inspect the runtime",
         model: "gpt-5.4-nano",
         provider: "openai"}
      )

    run_shell = %ToolUse{
      id: "call_1",
      name: "run_shell",
      input: %{
        "command" => "pwd",
        "description" => %{
          "action" => "Checking the working directory",
          "goals" => [
            "see where the shell starts",
            "confirm whether the workspace is correct",
            "avoid running later commands in the wrong place"
          ],
          "assumptions" => ["pwd is available in the shell"]
        }
      }
    }

    elixir_eval = %ToolUse{
      id: "call_2",
      name: "elixir_eval",
      input: %{
        "code" => "1 + 1",
        "description" => %{
          "action" => "Inspecting the runtime",
          "goals" => [
            "confirm eval is working",
            "inspect live state with real code",
            "avoid hand-waving about the runtime"
          ],
          "assumptions" => ["the live node is reachable"]
        }
      }
    }

    assert {:ok, %{execution: first_execution}} =
             GenServer.call(executor, {:prepare_tool, run_shell, %{cycle_id: "cycle_1"}})

    assert first_execution.input["send_control_prompt"] == true

    assert {:ok, %{execution: second_execution}} =
             GenServer.call(executor, {:prepare_tool, elixir_eval, %{cycle_id: "cycle_1"}})

    assert second_execution.input["send_control_prompt"] == false
    assert second_execution.input["topic"] == "cycle:cycle_1"
    assert second_execution.input["reply_to"] == 456
    refute Map.has_key?(second_execution.input, "control_prompt")
  end

  test "spawn_agent inherits reply_to for delegated cycles" do
    executor =
      start_supervised!(
        {AdhocToolExecutor,
         bot_id: "charlie",
         bot_username: "charliebuddybot",
         session_id: "charlie",
         chat_id: 123,
         reply_to: 456,
         prompt: "Delegate follow-up work",
         model: "gpt-5.4-mini",
         provider: "openai"}
      )

    tool_use = %ToolUse{
      id: "call_1",
      name: "spawn_agent",
      input: %{"prompt" => "Investigate and summarize the issue"}
    }

    assert {:ok, %{execution: execution}} =
             GenServer.call(executor, {:prepare_tool, tool_use, %{cycle_id: "cycle_1"}})

    assert execution.input["reply_to"] == 456
  end
end
