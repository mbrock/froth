defmodule Froth.Telegram.CostFooterTest do
  use Froth.TelegramBotCase, async: true

  alias Froth.Telegram.CostFooter

  test "appending a footer preserves Markdown entities on the sent message" do
    source = "*Italic*, **bold**, and `inline code` — formatting works."
    rendered = "Italic, bold, and inline code — formatting works."

    entities = [
      text_entity(0, 6, "textEntityTypeItalic"),
      text_entity(8, 4, "textEntityTypeBold"),
      text_entity(18, 11, "textEntityTypeCode")
    ]

    session_id =
      start_fake_session(
        request_handler: fn
          %{
            "@type" => "parseTextEntities",
            "text" =>
              "<i>Italic</i>, <b>bold</b>, and <code>inline code</code> — formatting works."
          } ->
            {:ok,
             %{
               "@type" => "formattedText",
               "text" => rendered,
               "entities" => entities
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
               last_sent_message_text: source,
               footer: "[1.2s | 3k in | $0.001]",
               reply_to: 456
             )

    assert_receive {:telegram_call,
                    %{
                      "@type" => "editMessageText",
                      "message_id" => 789,
                      "input_message_content" => %{
                        "text" => %{
                          "text" =>
                            "Italic, bold, and inline code — formatting works.\n\n[1.2s | 3k in | $0.001]",
                          "entities" => ^entities
                        }
                      }
                    }}
  end

  defp text_entity(offset, length, type) do
    %{
      "@type" => "textEntity",
      "offset" => offset,
      "length" => length,
      "type" => %{"@type" => type}
    }
  end
end
