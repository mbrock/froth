defmodule Froth.Follow.RendererTest do
  use ExUnit.Case, async: true

  alias Froth.Follow.{Entry, Renderer}

  test "smart rendering omits missing detail without crashing" do
    entry = %Entry{
      id: "evt_1",
      at: ~U[2026-03-24 13:00:00Z],
      event: "froth.agent.message.appended",
      family: "message",
      kind: "appended",
      level: :debug,
      scope: "user",
      summary: "message appended",
      detail: nil
    }

    rendered = Renderer.to_ansi(entry, :smart) |> IO.iodata_to_binary()

    assert rendered =~ "message"
    assert rendered =~ "message appended"
  end

  test "raw rendering omits empty optional segments without crashing" do
    entry = %Entry{
      id: "evt_2",
      at: ~U[2026-03-24 13:00:01Z],
      event: "froth.agent.control.outcome",
      family: "control",
      kind: "outcome",
      level: :info,
      summary: "reply sent",
      metadata: %{}
    }

    rendered = Renderer.to_ansi(entry, :raw) |> IO.iodata_to_binary()

    assert rendered =~ "froth.agent.control.outcome"
  end

  test "smart rendering includes aligned tree prefix information" do
    entry = %Entry{
      id: "evt_3",
      at: ~U[2026-03-24 13:00:02Z],
      family: "tool",
      kind: "completed",
      level: :info,
      scope: "run_shell",
      summary: "completed",
      detail: "exit=0",
      event: "froth.agent.tool.completed"
    }

    rendered = Renderer.to_ansi(entry, :smart, tree_prefix: "│ └") |> IO.iodata_to_binary()

    assert rendered =~ "run_shell"
    assert rendered =~ "│ └"
    assert rendered =~ "completed"
  end

  test "cycle summary rendering stays compact" do
    rendered =
      Renderer.cycle_summary_to_ansi(%{
        cycle_id: "01KMDKN3GHAC7B814PD3GB4THP",
        provider: "anthropic",
        model: "claude-opus-4-6",
        status: "completed",
        status_level: :info,
        tool_count: 3,
        llm_count: 1,
        elapsed_ms: 30_250
      })
      |> IO.iodata_to_binary()

    assert rendered =~ "summary"
    assert rendered =~ "tools=3"
    assert rendered =~ "llm=anthropic:claude-opus-4-6"
  end
end
