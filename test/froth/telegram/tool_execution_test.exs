defmodule Froth.Telegram.ToolExecutionTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Agent.{Surface, ToolUse}
  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Telegram.ToolExecution

  test "send_message renders model-authored Markdown through TDLib" do
    entity = %{
      "@type" => "textEntity",
      "offset" => 0,
      "length" => 4,
      "type" => %{"@type" => "textEntityTypeBold"}
    }

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "parseTextEntities",
            "text" => "<i>just</i> checking"
          } ->
            {:ok,
             %{
               "@type" => "formattedText",
               "text" => "just checking",
               "entities" => [entity]
             }}

          _ ->
            :default
        end
      )

    context = %Context{
      cycle_id: "cycle",
      surface: %Surface{session_id: session_id, chat_id: 123, reply_to: 456},
      view: %View{}
    }

    tool_use = %ToolUse{
      id: "call_1",
      name: "send_message",
      input: %{"text" => "*just* checking"}
    }

    assert %{result: {:ok, "sent"}} = ToolExecution.execute(context, tool_use)

    assert_receive {:telegram_call,
                    %{
                      "@type" => "parseTextEntities",
                      "parse_mode" => %{"@type" => "textParseModeHTML"},
                      "text" => "<i>just</i> checking"
                    }}

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "input_message_content" => %{
                        "text" => %{
                          "text" => "just checking",
                          "entities" => [^entity]
                        }
                      }
                    }}
  end

  test "narration rollover puts running controls on the new message" do
    %{bot_ref: bot_ref, session_id: session_id} = start_charlie_bot()
    {_pid, bot_config} = Froth.Telegram.Bot.snapshot(bot_ref)
    old_text = String.duplicate("x", 4_090)

    context = %Context{
      cycle_id: "cycle-rollover",
      bot_config: bot_config,
      surface: %Surface{session_id: session_id, chat_id: 123, reply_to: 456},
      view: %View{
        narration: %{message_id: 77, text: old_text, mode: :italic},
        control_message: %{message_id: 77, text: old_text, mode: :italic}
      }
    }

    tool_use = %ToolUse{
      id: "call-rollover",
      name: "unknown_test_tool",
      input: %{
        "description" => %{
          "action" => "Starting the next visible work segment",
          "goals" => [],
          "assumptions" => []
        }
      }
    }

    assert %{
             narration_message: %{message_id: new_message_id},
             control_message: %{message_id: control_message_id}
           } = ToolExecution.execute(context, tool_use)

    assert control_message_id == new_message_id

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "reply_markup" => %{
                        "@type" => "replyMarkupInlineKeyboard",
                        "rows" => [[open_button, stop_button]]
                      }
                    }}

    assert open_button["text"] == "Open"
    assert stop_button["text"] == "Stop"
  end
end
