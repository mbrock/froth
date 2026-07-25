defmodule FrothWeb.InferenceSessionsLiveTest do
  use FrothWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Froth.Agent
  alias Froth.Agent.Cycle
  alias Froth.Repo
  alias Froth.Telegram.CycleLink

  test "loads cycle summaries and messages from sequential cycle items", %{
    conn: conn
  } do
    cycle = Repo.insert!(%Cycle{status: :completed})

    Agent.append_message(cycle, :user, "hello", nil, 0)

    Agent.append_event(
      cycle,
      %{kind: "tool.started", data: %{"tool_name" => "echo"}},
      1
    )

    Agent.append_event(
      cycle,
      %{
        kind: "tool.completed",
        data: %{
          "tool_name" => "echo",
          "result_type" => "text",
          "result" => "done"
        }
      },
      2
    )

    Agent.append_message(cycle, :agent, "goodbye", nil, 3)

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: "charlie",
      chat_id: -100_123,
      reply_to: 456
    })

    {:ok, view, _html} = live(conn, ~p"/froth/inference/#{cycle.id}")

    assert has_element?(view, "#cycles-page")
    assert has_element?(view, "#cycle-#{cycle.id}")
    assert has_element?(view, "#cycle-detail")
    assert has_element?(view, "#cycle-messages")
    assert has_element?(view, "#cycle-msg-1")
    assert has_element?(view, "#cycle-msg-2")
  end
end
