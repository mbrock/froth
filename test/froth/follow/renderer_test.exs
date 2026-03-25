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
end
