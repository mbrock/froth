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
        %{
          provider: "anthropic",
          op: "append",
          resource_id: "message/blocks/0"
        }
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

  test "projects persisted control outcomes into semantic control entries" do
    entry =
      Projector.from_row(%{
        id: "evt_control",
        event: "froth.agent.control.outcome",
        inserted_at: ~U[2026-03-24 15:05:34Z],
        metadata: %{
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP",
          "outcome" => "yield",
          "reason" => "Waiting for subscribed tasks.",
          "tool_use_id" => "toolu_1234567890"
        }
      })

    assert entry.family == "control"
    assert entry.scope == "01KMDKN3"
    assert entry.summary == "yielded"
    assert entry.detail =~ "Waiting for subscribed tasks."
    assert entry.detail =~ "call=toolu_12"
    assert Entry.visible?(entry, :smart)
  end

  test "projects persisted message appends as hidden smart-mode entries" do
    entry =
      Projector.from_row(%{
        id: "evt_message",
        event: "froth.agent.message.appended",
        inserted_at: ~U[2026-03-24 15:05:34Z],
        metadata: %{
          "role" => "user",
          "content_kind" => "text",
          "text_preview" => "hello there"
        }
      })

    assert entry.family == "message"
    assert entry.scope == "user"
    assert entry.summary == "message appended"
    assert entry.hidden
    refute Entry.visible?(entry, :smart)
    assert Entry.visible?(entry, :raw)
  end

  test "keeps long message previews intact for follow rendering" do
    long_text = String.duplicate("the full preview should stay visible. ", 12)

    entry =
      Projector.from_row(%{
        id: "evt_message_long",
        event: "froth.agent.message.appended",
        inserted_at: ~U[2026-03-24 15:05:34Z],
        metadata: %{
          "role" => "user",
          "content_kind" => "text",
          "text_preview" => long_text
        }
      })

    assert entry.detail =~ long_text
    refute entry.detail =~ "..."
  end

  test "hides noisy codex streaming events in smart mode but keeps them in raw mode" do
    entry =
      Projector.from_live(
        [:froth, :codex, :data_chunk],
        %{},
        %{bytes: 512, complete_lines: 3, buffered_bytes: 22}
      )

    assert entry.family == "codex"
    assert entry.summary == "streaming data"
    assert entry.hidden
    refute Entry.visible?(entry, :smart)
    assert Entry.visible?(entry, :raw)
  end

  test "projects browser screenshots into readable hidden smart-mode entries" do
    entry =
      Projector.from_live(
        [:froth, :browser, :session, :screenshot],
        %{},
        %{
          browser_id: "browser:f4f02a04aecc",
          path: "/home/mbrock/froth/priv/route_audit/screenshots/043-api.png"
        }
      )

    assert entry.family == "browser"
    assert entry.scope == "f4f02a04"
    assert entry.summary == "captured screenshot"
    assert entry.detail == "screenshots/043-api.png"
    assert entry.hidden
    refute Entry.visible?(entry, :smart)
    assert Entry.visible?(entry, :raw)
  end

  test "projects browser cdp requests without false detail noise" do
    entry =
      Projector.from_live(
        [:froth, :browser, :cdp, :request],
        %{},
        %{
          id: 353,
          method: "Page.navigate",
          session_id: "C987F8DEA048A0065EBFDF357B2D31F6"
        }
      )

    assert entry.family == "browser"
    assert entry.scope == "Page.navigate"
    assert entry.summary == "cdp Page.navigate"
    assert entry.detail =~ "id=353"
    assert entry.detail =~ "session=C987F8DE"
    assert entry.hidden
  end

  test "hides persisted tool spine rows in smart mode when a telemetry twin exists" do
    entry =
      Projector.from_row(%{
        id: "evt_tool",
        event: "froth.agent.tool.completed",
        inserted_at: ~U[2026-03-24 15:05:34Z],
        measurements: %{"duration_ms" => 56},
        metadata: %{
          "kind" => "tool.completed",
          "tool_name" => "read_tool_transcript",
          "cycle_id" => "01KMDKN3GHAC7B814PD3GB4THP"
        }
      })

    assert entry.family == "tool"
    assert entry.hidden
    refute Entry.visible?(entry, :smart)
    assert Entry.visible?(entry, :raw)
  end

  test "renders tuple-shaped error metadata without crashing" do
    entry =
      Projector.from_live(
        [:froth, :codex, :request_failed_to_send],
        %{},
        %{error: {:shutdown, {:remote, :boom}}, reason: {:error, :timeout}}
      )

    assert entry.family == "codex"
    assert entry.level == :error
    assert entry.detail =~ "{:error, :timeout}"
    assert entry.detail =~ "{:shutdown, {:remote, :boom}}"
  end

  test "renders provider request exception tuples without crashing" do
    entry =
      Projector.from_live(
        [:froth, :anthropic, :request, :exception],
        %{},
        %{
          model: "claude-opus-4-6",
          error:
            {:provider_error, "anthropic",
             %{
               "error" => %{
                 "message" => "Internal server error",
                 "type" => "api_error"
               }
             }, %{}}
        }
      )

    assert entry.family == "llm"
    assert entry.level == :error
    assert entry.summary == "request failed"
    assert entry.detail =~ "model=claude-opus-4-6"
    assert entry.detail =~ "Internal server error"
  end

  test "renders codex request errors with compact scope and previews" do
    entry =
      Projector.from_live(
        [:froth, :codex, :request_error_response],
        %{},
        %{
          method: "item/agentMessage/delta",
          topic: "codex:wire:codex_384e409b",
          id: 17,
          error_preview: "%{\"message\" => \"boom\"}"
        }
      )

    assert entry.family == "codex"
    assert entry.scope == "agentMessage/delta"
    assert entry.summary == "request error response"
    assert entry.detail =~ "method=agentMessage/delta"
    assert entry.detail =~ "topic=codex_384e409b"
    assert entry.detail =~ "error=%{\"message\" => \"boom\"}"
    refute entry.hidden
  end
end
