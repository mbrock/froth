defmodule Froth.Follow.RendererTest do
  use ExUnit.Case, async: true

  alias Froth.Follow.{Entry, Renderer}

  test "smart rendering keeps the open symbol and flat indentation" do
    entry = %Entry{
      id: "evt_1",
      at: ~U[2026-03-24 13:00:00Z],
      event: "froth.agent.cycle.started",
      family: "cycle",
      kind: "started",
      level: :info,
      scope: "01KMDKN3GHAC7B814PD3GB4THP",
      summary: "started",
      detail: "model=claude-opus-4-6 provider=anthropic"
    }

    rendered =
      Renderer.to_ansi(entry, :smart, tree_prefix: "│ └")
      |> IO.iodata_to_binary()
      |> strip_ansi()

    [primary, secondary] = String.split(rendered, "\n", parts: 2)

    assert String.starts_with?(primary, "   ✱")
    assert primary =~ "✱"
    assert primary =~ "cycle"
    assert primary =~ "started"
    assert String.starts_with?(secondary, "   13:00:00")
    assert secondary =~ "13:00:00"
    assert secondary =~ "model=claude-opus-4-6"
    refute rendered =~ ~r/[│├└]/u
  end

  test "smart rendering keeps empty secondary content readable" do
    entry = %Entry{
      id: "evt_2",
      at: ~U[2026-03-24 13:00:01Z],
      event: "froth.agent.message.appended",
      family: "message",
      kind: "appended",
      level: :debug,
      scope: "user",
      summary: "message appended",
      detail: nil
    }

    rendered =
      Renderer.to_ansi(entry, :smart)
      |> IO.iodata_to_binary()
      |> strip_ansi()

    [primary, secondary] = String.split(rendered, "\n", parts: 2)

    assert primary =~ "message appended"
    assert primary =~ "❡"
    assert secondary =~ "-"
  end

  test "raw rendering keeps metadata intact with flat indentation" do
    entry = %Entry{
      id: "evt_3",
      at: ~U[2026-03-24 13:00:02Z],
      event: "froth.agent.tool.started",
      family: "tool",
      kind: "started",
      level: :info,
      summary: "started",
      duration_ms: 56,
      metadata: %{
        "op" => "append",
        "provider" => "anthropic",
        "note" => "this string should stay fully visible without truncation"
      }
    }

    rendered =
      Renderer.to_ansi(entry, :raw, tree_prefix: "│ └")
      |> IO.iodata_to_binary()
      |> strip_ansi()

    [primary, secondary] = String.split(rendered, "\n", parts: 2)

    assert String.starts_with?(primary, "   ✱")
    assert primary =~ "✱"
    assert primary =~ "froth.agent.tool.started"
    assert secondary =~ "56ms"
    assert secondary =~ "provider=anthropic"

    assert secondary =~
             "this string should stay fully visible without truncation"

    refute rendered =~ ~r/[│├└]/u
  end

  test "smart rendering keeps indentation on both lines" do
    entry = %Entry{
      id: "evt_4",
      at: ~U[2026-03-24 13:00:03Z],
      family: "tool",
      kind: "completed",
      level: :info,
      scope: "run_shell",
      summary: "completed",
      detail: "exit=0",
      event: "froth.agent.tool.completed"
    }

    rendered =
      Renderer.to_ansi(entry, :smart, tree_prefix: "│ └")
      |> IO.iodata_to_binary()
      |> strip_ansi()

    [primary, secondary] = String.split(rendered, "\n", parts: 2)

    assert String.starts_with?(primary, "   ◉")
    assert primary =~ "◉"
    assert primary =~ "run_shell"
    assert primary =~ "completed"
    assert String.starts_with?(secondary, "   13:00:03")
    assert secondary =~ "exit=0"
    refute rendered =~ ~r/[│├└]/u
  end

  test "cycle summary rendering becomes a two-line block" do
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
      |> strip_ansi()

    [primary, secondary] = String.split(rendered, "\n", parts: 2)

    assert primary =~ "◉"
    assert primary =~ "01KMDKN3GHAC7B814PD3GB4THP"
    assert primary =~ "completed"
    assert secondary =~ "llm=anthropic:claude-opus-4-6"
    assert secondary =~ "tools=3"
    assert secondary =~ "reqs=1"
    assert secondary =~ "elapsed=30.3s"
    refute rendered =~ "status="
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[\d;]*m/, text, "")
  end
end
