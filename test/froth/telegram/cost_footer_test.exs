defmodule Froth.Telegram.CostFooterTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Telegram.CostFooter

  test "appending a footer preserves Markdown entities on the sent message" do
    entity = %{
      "@type" => "textEntity",
      "offset" => 0,
      "length" => 12,
      "type" => %{"@type" => "textEntityTypeBold"}
    }

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "parseTextEntities",
            "text" => "*one more try*"
          } ->
            {:ok,
             %{
               "@type" => "formattedText",
               "text" => "one more try",
               "entities" => [entity]
             }}

          _ ->
            :default
        end
      )

    assert :ok =
             CostFooter.apply(
               session_id: session_id,
               chat_id: 123,
               last_sent_message_id: 789,
               last_sent_message_text: "*one more try*",
               footer: "[1.2s | 3k in | $0.001]",
               reply_to: 456
             )

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "message_id" => 789,
                      "input_message_content" => %{
                        "text" => %{
                          "text" => "one more try\n\n[1.2s | 3k in | $0.001]",
                          "entities" => [^entity]
                        }
                      }
                    }}
  end
end
