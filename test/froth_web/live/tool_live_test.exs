defmodule FrothWeb.ToolLiveTest do
  use FrothWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.Repo
  alias Froth.Telegram.CycleLink

  test "shows stop affordance for a loaded cycle even when transcript looks complete",
       %{
         conn: conn
       } do
    cycle = Repo.insert!(%Cycle{})
    message = Repo.insert!(Message.agent("complete enough to look done"))
    Agent.append_event(cycle, %{head_id: message.id, message_id: message.id})

    {:ok, view, _html} =
      live(conn, ~p"/froth/mini/tool/cycle_missingbot_#{cycle.id}")

    assert has_element?(view, "#loop-stop")
    assert has_element?(view, "#loop-close")

    view
    |> element("#loop-stop")
    |> render_click()

    refute has_element?(view, "#loop-stop")
    assert has_element?(view, "#tool-loop-viewer", "stop requested")
  end

  test "renders narration-first tool cards with compact raw sections and exit badges",
       %{
         conn: conn
       } do
    cycle = Repo.insert!(%Cycle{})

    tool_use =
      Repo.insert!(
        Message.agent([
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "run_shell",
            "input" => %{
              "command" => "printf 'froth\\n'",
              "description" => %{
                "action" => "Checking the shell output before replying.",
                "goals" => [
                  "inspect the command output",
                  "see whether the command crashed",
                  "avoid summarizing a result I have not read"
                ],
                "assumptions" => ["printf is available in the shell"]
              }
            }
          }
        ])
      )

    tool_result =
      Repo.insert!(%{
        Message.user([
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => "Shell shell:test (exit code: 139)\nsegfault"
          }
        ])
        | parent_id: tool_use.id
      })

    Agent.append_event(cycle, %{
      head_id: tool_result.id,
      message_id: tool_result.id
    })

    {:ok, view, _html} =
      live(conn, ~p"/froth/mini/tool/cycle_missingbot_#{cycle.id}")

    assert has_element?(
             view,
             "#tool-feed",
             "Checking the shell output before replying."
           )

    assert has_element?(view, "#tool-input-call_1[open]")
    assert has_element?(view, "#tool-output-call_1[open]")
    assert has_element?(view, "#tool-feed span", "exit 139")
  end

  test "renders markdown transcript and steer controls for active telegram cycles",
       %{conn: conn} do
    cycle = Repo.insert!(%Cycle{})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: "charlie",
      chat_id: 123,
      reply_to: 456
    })

    message =
      Repo.insert!(
        Message.agent([
          %{"type" => "text", "text" => "**Bold** reply"},
          %{
            "type" => "tool_use",
            "id" => "call_active",
            "name" => "timeline",
            "input" => %{"narration" => "Checking the current logs."}
          }
        ])
      )

    Agent.append_event(cycle, %{head_id: message.id, message_id: message.id})

    {:ok, view, _html} =
      live(conn, ~p"/froth/mini/tool/cycle_charlie_#{cycle.id}")

    assert has_element?(view, "#tool-follow-tail")
    assert has_element?(view, "#tool-item-0 strong", "Bold")
    assert has_element?(view, "#loop-steer-form")
    assert has_element?(view, "#loop-steer", "Queue")
  end

  test "hides injected telegram context while preserving the cycle work", %{
    conn: conn
  } do
    cycle = Repo.insert!(%Cycle{})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: "charlie",
      chat_id: 123,
      reply_to: 456
    })

    context =
      Repo.insert!(
        Message.user("<chronicle>seven weeks of private context</chronicle>")
      )

    work =
      Repo.insert!(%{
        Message.agent([
          %{
            "type" => "thinking",
            "thinking" => "Inspecting the actual task."
          },
          %{"type" => "text", "text" => "Here is the useful result."}
        ])
        | parent_id: context.id
      })

    Agent.append_event(cycle, %{head_id: work.id, message_id: work.id})

    {:ok, view, _html} =
      live(conn, ~p"/froth/mini/tool/cycle_charlie_#{cycle.id}")

    refute has_element?(view, "#tool-feed", "seven weeks of private context")
    assert has_element?(view, "#tool-feed", "Inspecting the actual task.")
    assert has_element?(view, "#tool-feed", "Here is the useful result.")
  end

  test "renders xml-like transcript tags literally instead of as html", %{
    conn: conn
  } do
    cycle = Repo.insert!(%Cycle{})

    message =
      Repo.insert!(
        Message.agent([
          %{
            "type" => "text",
            "text" =>
              "<summary date=\"2026-03-22\">\nA scandal in tags.\n</summary>\n\n**Bold** still works."
          }
        ])
      )

    Agent.append_event(cycle, %{head_id: message.id, message_id: message.id})

    {:ok, view, _html} =
      live(conn, ~p"/froth/mini/tool/cycle_missingbot_#{cycle.id}")

    assert has_element?(view, "#tool-item-0", ~s(<summary date="2026-03-22">))
    assert has_element?(view, "#tool-item-0", "</summary>")
    assert has_element?(view, "#tool-item-0 strong", "Bold")
  end
end
