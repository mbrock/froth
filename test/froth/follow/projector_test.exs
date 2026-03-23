defmodule Froth.Follow.ProjectorTest do
  use ExUnit.Case, async: true

  alias Froth.Follow.{Entry, Projector}

  test "projects tool completion into a semantic entry" do
    entry =
      Projector.from_live(
        [:froth, :agent, :tool, :completed],
        %{duration_ms: 56},
        %{
          tool_name: "read_tool_transcript",
          cycle_id: "01KMDKN3GHAC7B814PD3GB4THP",
          result_type: :text
        }
      )

    assert entry.family == "tool"
    assert entry.scope == "read_tool_transcript"
    assert entry.summary == "completed"
    assert entry.detail =~ "56ms"
    assert entry.detail =~ "result=text"
    assert entry.detail =~ "cycle=01KMDKN3"
    assert entry.level == :info
    assert Entry.visible?(entry, :smart)
  end

  test "projects cycle completion from persisted event rows" do
    entry =
      Projector.from_row(%{
        id: "evt_1",
        event: "froth.agent.cycle.stop",
        inserted_at: ~U[2026-03-23 15:05:34Z],
        measurements: %{"duration_ms" => 17792},
        metadata: %{
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP",
          "reason" => "normal",
          "phase" => "done"
        }
      })

    assert entry.family == "cycle"
    assert entry.scope == "01KMDKN3"
    assert entry.summary == "completed"
    assert entry.detail =~ "17792ms"
    assert entry.level == :info
  end

  test "hides noisy llm edit events in smart mode but keeps them in raw mode" do
    entry =
      Projector.from_live(
        [:froth, :llm, :edit],
        %{},
        %{provider: "anthropic", op: "append", resource_id: "message/blocks/0"}
      )

    assert entry.hidden
    refute Entry.visible?(entry, :smart)
    assert Entry.visible?(entry, :raw)
    refute Entry.visible?(entry, :errors)
  end

  test "treats telegram mention updates as visible semantic entries" do
    entry =
      Projector.from_live(
        [:froth, :telegram, :bot, :update],
        %{},
        %{
          action: "mention",
          update_type: "updateNewMessage",
          bot_id: "charlie",
          text: "charlie hi"
        }
      )

    assert entry.family == "telegram"
    assert entry.scope == "charlie"
    assert entry.summary == "mention received"
    assert entry.detail =~ "type=updateNewMessage"
    assert entry.detail =~ "text=charlie hi"
    refute entry.hidden
  end
end
