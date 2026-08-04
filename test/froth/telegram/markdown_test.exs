defmodule Froth.Telegram.MarkdownTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Markdown

  test "converts the CommonMark formatting agents actually produce" do
    markdown =
      "*Italic*, **bold**, and `inline code` — the formatting test works."

    assert {:ok, html} = Markdown.to_telegram_html(markdown)

    assert html ==
             "<i>Italic</i>, <b>bold</b>, and <code>inline code</code> — the formatting test works."
  end

  test "renders common block structures without unsupported HTML tags" do
    markdown = """
    # Heading

    - one
    - two

    > quoted
    """

    assert {:ok, html} = Markdown.to_telegram_html(markdown)

    assert html ==
             "<b>Heading</b>\n\n• one\n• two\n\n<blockquote>quoted</blockquote>"
  end

  test "escapes source text and link attributes before TDLib parses HTML" do
    assert {:ok, html} =
             Markdown.to_telegram_html(
               "A < B and [link](https://example.com/?a=1&b=2)"
             )

    assert html ==
             "A &lt; B and <a href=\"https://example.com/?a=1&amp;b=2\">link</a>"
  end
end
