defmodule Froth.Telegram.BotContextHTMLTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.BotContextHTML
  alias Froth.Telegram.BotContextHTML.Context

  defp render(component) do
    BotContextHTML.render_to_string(component)
  end

  describe "summary/1" do
    test "renders a summary with date" do
      html = render(BotContextHTML.summary(%{date: "2026-03-05", text: "A quiet day."}))

      assert html =~ ~s(<summary date="2026-03-05">)
      assert html =~ "A quiet day."
      assert html =~ "</summary>"
    end
  end

  describe "recent/1" do
    test "renders recent messages with structured msg tags" do
      messages = [
        %{time: "2026-03-06 09:12 UTC", sender: "@mikkel", message_id: 4401, text: "morning"}
      ]

      html = render(BotContextHTML.recent(%{messages: messages}))

      assert html =~
               ~s(<msg message_id="4401" sender="@mikkel" time="2026-03-06 09:12 UTC" type="messageText">)

      assert html =~ "morning"
    end
  end

  describe "cycle rendering" do
    test "renders json call input and return blocks inside a cycle" do
      html =
        render(
          BotContextHTML.cycle_trace(%{
            cycle_id: "abc",
            time: "2026-03-06 09:21:33 UTC",
            entries: [
              %{
                kind: :call,
                tool: "search",
                input_json: ~s({"query":["froth"]})
              },
              %{kind: :return, text: "found signal"}
            ]
          })
        )

      assert html =~ ~s(<cycle cycle_id="abc" at="2026-03-06 09:21:33 UTC">)
      assert html =~ ~s(<call tool="search">)
      assert html =~ ~s({"query":["froth"]})
      assert html =~ "<return>"
      assert html =~ "found signal"
      assert html =~ "</cycle>"
    end

    test "return text truncates to 500 chars" do
      html = render(BotContextHTML.cycle_return(%{text: String.duplicate("x", 600)}))

      [_, inner] = String.split(html, "<return>", parts: 2)
      [inner, _] = String.split(inner, "</return>", parts: 2)
      assert String.length(String.trim(inner)) == 500
    end
  end

  describe "context/1 (top-level)" do
    test "renders the sample context with all sections" do
      html = render(BotContextHTML.context(%{ctx: BotContextHTML.sample_context()}))

      # summaries
      assert html =~ ~s(<summary date="2026-03-04">)
      assert html =~ "memory leak"
      assert html =~ ~s(<summary date="2026-03-05">)
      assert html =~ "voice transcription"

      # recent
      assert html =~ "@mikkel"
      assert html =~ "checking the logs"

      # cycle traces are attached to recent messages
      assert html =~ ~s(<cycle cycle_id="01JNWXYZ")
      assert html =~ ~s(<call tool="search">)
      assert html =~ ~s({"query":["context","builder"]})
      assert html =~ ~s(<cycle cycle_id="01JNWABC")
      assert html =~ ~s(<call tool="look">)

      # newest user message is part of the same <msg> stream
      assert html =~ ~s(<msg message_id="4405" sender="user:42")
      assert html =~ "what does the context look like right now?"
      refute html =~ "<previous_cycle"
    end

    test "renders minimal context with only recent messages" do
      ctx = %Context{
        recent_messages: [
          %{time: "2026-03-06 09:30 UTC", sender: "user:99", message_id: 1, text: "hi"}
        ]
      }

      html = render(BotContextHTML.context(%{ctx: ctx}))

      assert html =~ ~s(<msg message_id="1" sender="user:99")
      assert html =~ "hi"
      refute html =~ "<summary"
      refute html =~ "<previous_cycle"
    end
  end

  describe "render_to_string/1" do
    test "returns a trimmed binary" do
      result =
        BotContextHTML.render_to_string(
          BotContextHTML.recent_message(%{
            time: "2026-03-06 09:12 UTC",
            sender: "user:1",
            message_id: 1,
            text: "hi"
          })
        )

      assert is_binary(result)
      refute String.starts_with?(result, "\n")
      refute String.ends_with?(result, "\n")
    end

    test "adds a newline before closing a cycle with block children" do
      html =
        BotContextHTML.render_to_string(
          BotContextHTML.cycle_trace(%{
            cycle_id: "abc",
            time: "2026-03-06 09:21:33 UTC",
            entries: [
              %{kind: :call, tool: "look", input_json: ~s({"message_id":"4401"})},
              %{kind: :return, text: "ok"}
            ]
          })
        )

      assert html =~ "</return>\n</cycle>"
    end
  end

  describe "context/1 and render_to_parts/1" do
    test "splits rendered context on template page breaks" do
      ctx = %Context{
        summaries: [
          %{date: "2026-03-04", text: "Summary one"},
          %{date: "2026-03-05", text: "Summary two"}
        ],
        chat_context: %{
          chat_id: -100_123,
          chat_name: "Froth chat",
          participants: [%{id: 42, label: "@mikkel"}, %{id: 43, label: "@luna"}],
          omitted_count: 1
        },
        recent_messages: [
          %{time: "2026-03-06 09:12 UTC", sender: "@mikkel", message_id: 4401, text: "hi"},
          %{time: "2026-03-06 09:13 UTC", sender: "@luna", message_id: 4402, text: "hey"}
        ]
      }

      parts =
        BotContextHTML.context(%{ctx: ctx})
        |> BotContextHTML.render_to_parts()

      assert length(parts) == 5

      assert Enum.at(parts, 0) =~ ~s(<summary date="2026-03-04">)
      assert Enum.at(parts, 0) =~ "Summary one"
      assert Enum.at(parts, 1) =~ ~s(<summary date="2026-03-05">)
      assert Enum.at(parts, 1) =~ "Summary two"
      assert Enum.at(parts, 2) =~ "chat_id=-100123"
      assert Enum.at(parts, 2) =~ "chat_name=Froth chat"
      assert Enum.at(parts, 2) =~ "- @mikkel [id=42]"
      assert Enum.at(parts, 2) =~ "- ... 1 more participants omitted"
      assert Enum.at(parts, 3) =~ ~s(<msg message_id="4401")
      assert Enum.at(parts, 3) =~ "hi"
      assert Enum.at(parts, 4) =~ ~s(<msg message_id="4402")
      assert Enum.at(parts, 4) =~ "hey"
    end

    test "drops html comment nodes from rendered parts" do
      parts =
        Phoenix.HTML.raw("""
        <a>one</a>
        <!-- transient -->
        <b>two</b>
        """)
        |> BotContextHTML.render_to_parts()

      assert length(parts) == 1
      refute Enum.at(parts, 0) =~ "<!--"
      assert Enum.at(parts, 0) =~ "<a>"
      assert Enum.at(parts, 0) =~ "<b>"
    end

    test "render_to_string removes internal page break markers" do
      html =
        BotContextHTML.render_to_string(
          BotContextHTML.context(%{
            ctx: %Context{
              summaries: [
                %{date: "2026-03-04", text: "Summary one"},
                %{date: "2026-03-05", text: "Summary two"}
              ]
            }
          })
        )

      refute html =~ <<31>>
      assert html =~ "Summary one"
      assert html =~ "Summary two"
    end
  end
end
