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
end
