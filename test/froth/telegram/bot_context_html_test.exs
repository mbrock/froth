defmodule Froth.Telegram.BotContextHTMLTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.BotContextHTML
  alias Froth.Telegram.BotContextHTML.Context

  defp render(component) do
    BotContextHTML.render_to_string(component)
  end

  describe "chapter/1" do
    test "renders a chapter with name" do
      html =
        render(
          BotContextHTML.chapter(%{name: "2026-03-05", text: "A quiet day."})
        )

      assert html =~ ~s(<chapter name=2026-03-05>)
      assert html =~ "A quiet day."
      assert html =~ "</chapter>"
    end
  end

  describe "recent/1" do
    test "renders recent messages with structured msg tags" do
      messages = [
        %{
          date: 1_772_788_320,
          sender: "@mikkel",
          message_id: 4401,
          text: "morning"
        }
      ]

      html = render(BotContextHTML.recent(%{messages: messages}))

      assert html =~ ~s(<text id=tg:4401)
      assert html =~ ~s(from=@mikkel)
      assert html =~ "morning"
    end
  end

  describe "cycle rendering" do
    test "list-valued input renders repeated child tags" do
      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "abc",
            inserted_at: ~U[2026-03-06 09:21:33Z],
            entries: [
              %{
                kind: :call,
                tool: "search",
                input: %{"query" => ["froth"]}
              },
              %{kind: :return, outcome: {:ok, "found signal"}}
            ]
          })
        )

      assert html =~
               ~s(<cycle id=abc for=tg:4401 time="2026-03-06 09:21:33 UTC">)

      assert html =~ ~s(<call tool=search>)
      assert html =~ "<query>"
      assert html =~ "froth"
      assert html =~ "</query>"
      assert html =~ "<return>"
      assert html =~ "found signal"
    end

    test "long scalar values stay as child elements" do
      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "abc",
            inserted_at: ~U[2026-03-06 09:21:33Z],
            entries: [
              %{
                kind: :call,
                tool: "run_shell",
                input: %{
                  "command" => "rg 'foo' lib | head -5",
                  "description" => %{"action" => "searching for foo"}
                }
              }
            ]
          })
        )

      # `command` is a safe-enough string (< 60 chars, no newline) so
      # it becomes an attribute; since <command> is a void tag it falls
      # back to <field name="command">. The nested description map
      # collapses its short scalar fields to attrs on <description>.
      assert html =~ ~s(<call tool=run_shell)
      assert html =~ "command=\"rg 'foo' lib | head -5\""
      assert html =~ ~s(<description action="searching for foo")
    end

    test "multi-line scalar values stay as child element bodies" do
      code = "Enum.map(1..10, fn n ->\n  n * n\nend)"

      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "def",
            inserted_at: ~U[2026-03-06 09:22:00Z],
            entries: [
              %{
                kind: :call,
                tool: "elixir_eval",
                input: %{"code" => code, "topic" => "cycle:abc"}
              }
            ]
          })
        )

      # Multi-line code must not be collapsed into an attribute.
      assert html =~ "<code>"
      assert html =~ "Enum.map(1..10, fn n ->"
      assert html =~ "</code>"
      # Short, single-line `topic` goes on the enclosing tag as an attr.
      assert html =~ ~s(topic=cycle:abc)
    end

    test "short scalar inputs render as attributes on <call>" do
      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "ghi",
            inserted_at: ~U[2026-03-06 09:23:00Z],
            entries: [
              %{
                kind: :call,
                tool: "pager",
                input: %{
                  "id" => "blob:01KP",
                  "mode" => "grep",
                  "pattern" => "error"
                }
              }
            ]
          })
        )

      assert html =~
               ~s(<call tool=pager id=blob:01KP mode=grep pattern=error />)
    end

    test "returning a block list uses the compact trace renderer" do
      blocks = [
        Froth.Context.Block.new(
          [kind: "shell", task_id: "shell:abc", size: 11, lines: 1],
          "hello world"
        )
      ]

      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "abc",
            inserted_at: ~U[2026-03-06 09:21:33Z],
            entries: [%{kind: :return, outcome: {:ok, blocks}}]
          })
        )

      assert html =~ "<shell"
      assert html =~ ~s(task_id=shell:abc)
      assert html =~ "hello world"
    end

    test "errored returns render <return is_error=\"true\">" do
      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "abc",
            inserted_at: ~U[2026-03-06 09:21:33Z],
            entries: [%{kind: :return, outcome: {:error, "nope"}}]
          })
        )

      assert html =~ ~s(<return is_error=true>)
      assert html =~ "nope"
    end

    test "failure intervention renders a structured <intervention> element" do
      html =
        render(
          BotContextHTML.cycle_trace(%{
            msg_id: "tg:4401",
            cycle_id: "abc",
            inserted_at: ~U[2026-03-06 09:21:33Z],
            entries: [
              %{
                kind: :intervention,
                data: %{
                  "kind" => "failure_intervention",
                  "designation" => "retry_with_hint",
                  "reason" => "shell exited 127",
                  "pending_ask_id" => "ask_42"
                }
              }
            ]
          })
        )

      assert html =~ "<intervention"
      assert html =~ ~s(designation=retry_with_hint)
      assert html =~ ~s(reason="shell exited 127")
      assert html =~ ~s(pending_ask=ask_42)
    end
  end

  describe "context/1 (top-level)" do
    test "renders the sample context with recent messages and cycles" do
      html =
        render(
          BotContextHTML.context(%{ctx: BotContextHTML.sample_context()})
        )

      # recent
      assert html =~ "@mikkel"
      assert html =~ "checking the logs"

      # cycle traces follow their messages as siblings
      assert html =~ ~s(<cycle id=01JNWXYZ)
      assert html =~ ~s(<call tool=timeline)
      assert html =~ "<query>"
      assert html =~ "context"
      assert html =~ "builder"
      assert html =~ ~s(<cycle id=01JNWABC)
      assert html =~ ~s(<call tool=fetch)

      # newest user message is part of the same <msg> stream
      assert html =~ ~s(<text id=tg:4405)
      assert html =~ ~s(from=user:42)
      assert html =~ "what does the context look like right now?"
      refute html =~ "<previous_cycle"
    end

    test "renders minimal context with only recent messages" do
      ctx = %Context{
        recent_messages: [
          %{date: 1_741_253_400, sender: "user:99", message_id: 1, text: "hi"}
        ]
      }

      html = render(BotContextHTML.context(%{ctx: ctx}))

      assert html =~ ~s(<text id=tg:1)
      assert html =~ ~s(from=user:99)
      assert html =~ "hi"
      refute html =~ "<chapter"
      refute html =~ "<info>"
      refute html =~ "<previous_cycle"
    end
  end

  describe "render_to_string/1" do
    test "returns a trimmed binary" do
      result =
        BotContextHTML.render_to_string(
          BotContextHTML.recent_message(%{
            date: 1_741_252_320,
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
            msg_id: "tg:4401",
            cycle_id: "abc",
            inserted_at: ~U[2026-03-06 09:21:33Z],
            entries: [
              %{kind: :call, tool: "fetch", input: %{"message_id" => "4401"}},
              %{kind: :return, outcome: {:ok, "ok"}}
            ]
          })
        )

      assert html =~ "</return>\n</cycle>"
    end
  end

  describe "context/1 and render_to_parts/1" do
    test "splits rendered context on template page breaks" do
      ctx = %Context{
        chapters: [
          %{name: "ch01", text: "Summary one"},
          %{name: "ch02", text: "Summary two"}
        ],
        chat_context: %{
          chat_id: -100_123,
          chat_name: "Froth chat",
          participants: [
            %{id: 42, label: "@mikkel", latest_date: 1_741_252_390},
            %{id: 43, label: "@luna", latest_date: 1_741_252_380}
          ],
          omitted_count: 1
        },
        recent_messages: [
          %{
            date: 1_741_252_320,
            sender: "@mikkel",
            message_id: 4401,
            text: "hi"
          },
          %{
            date: 1_741_252_380,
            sender: "@luna",
            message_id: 4402,
            text: "hey"
          }
        ]
      }

      parts =
        BotContextHTML.context(%{ctx: ctx})
        |> BotContextHTML.render_to_parts()

      assert length(parts) == 5

      assert Enum.at(parts, 0) =~ ~s(<chapter name=ch01>)
      assert Enum.at(parts, 0) =~ "Summary one"
      assert Enum.at(parts, 1) =~ ~s(<chapter name=ch02>)
      assert Enum.at(parts, 1) =~ "Summary two"
      assert Enum.at(parts, 2) =~ ~s(<text id=tg:4401)
      assert Enum.at(parts, 2) =~ "hi"
      assert Enum.at(parts, 3) =~ ~s(<text id=tg:4402)
      assert Enum.at(parts, 3) =~ "hey"
      assert Enum.at(parts, 4) =~ "<info>"
      assert Enum.at(parts, 4) =~ ~s(<chat name="Froth chat" id=tg:-100123)
      assert Enum.at(parts, 4) =~ "<info>"
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
              chapters: [
                %{name: "ch01", text: "Summary one"},
                %{name: "ch02", text: "Summary two"}
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
