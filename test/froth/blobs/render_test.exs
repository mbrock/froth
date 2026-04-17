defmodule Froth.Blobs.RenderTest do
  use ExUnit.Case, async: true

  alias Froth.{Blobs, Repo}
  alias Froth.Blobs.Render

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "tool_return/2 — inline (small)" do
    test "wraps a small body in <output> without creating a blob" do
      {:ok, text} = Render.tool_return("hello world", kind: "shell")
      assert text =~ ~s(<output kind="shell" size="11" lines="1")
      assert text =~ "hello world"
      refute text =~ "blob:"
      refute text =~ "pager"
    end

    test "includes user-provided attrs on the open tag" do
      {:ok, text} =
        Render.tool_return("ok", kind: "shell", attrs: [task_id: "shell:abc", exit_code: 0])

      assert text =~ ~s(task_id="shell:abc")
      assert text =~ ~s(exit_code="0")
    end

    test "drops nil attr values" do
      {:ok, text} = Render.tool_return("x", kind: "eval", attrs: [session: nil, topic: "t"])
      refute text =~ "session="
      assert text =~ ~s(topic="t")
    end

    test "escapes attr values" do
      {:ok, text} = Render.tool_return("x", kind: "shell", attrs: [label: ~s(he said "hi")])
      assert text =~ ~s(label="he said &quot;hi&quot;")
    end
  end

  describe "tool_return/2 — folded (large)" do
    test "stores a blob and renders head + omitted note + tail" do
      body = Enum.map_join(1..80, "\n", &"line #{&1}")

      {:ok, text} = Render.tool_return(body, kind: "shell")

      assert text =~ ~r/<output kind="shell" blob="blob:[0-9A-HJKMNP-TV-Z]{26}"/
      assert text =~ ~s(lines="80")
      assert text =~ "head (lines 1–10):"
      assert text =~ "line 1"
      assert text =~ "line 10"

      assert text =~
               ~r/\(65 lines omitted — use pager id=blob:[0-9A-HJKMNP-TV-Z]{26} mode=read from_line=11/

      assert text =~ "tail (lines 76–80):"
      assert text =~ "line 80"
      # middle should not appear
      refute text =~ "line 42"
    end

    test "the stored blob holds the full body" do
      body = Enum.map_join(1..100, "\n", &"row #{&1}")
      {:ok, text} = Render.tool_return(body, kind: "shell")
      [blob_id] = Regex.run(~r/blob:([0-9A-HJKMNP-TV-Z]{26})/, text, capture: :all_but_first)

      assert {:ok, blob} = Blobs.get(blob_id)
      assert blob.bytes == body
      assert blob.lines == 100
    end

    test "folds on line count even if bytes fit" do
      # 100 very short lines, still well under 1200 bytes total
      body = Enum.map_join(1..100, "\n", fn _ -> "x" end)
      {:ok, text} = Render.tool_return(body, kind: "shell")
      assert text =~ "head (lines 1–10):"
      assert text =~ "tail (lines 96–100):"
    end

    test "folds on byte count even if line count fits" do
      body = String.duplicate("a", 2000)
      {:ok, text} = Render.tool_return(body, kind: "shell")
      assert text =~ "blob:"
    end

    test "respects custom head/tail windows" do
      body = Enum.map_join(1..100, "\n", &"r#{&1}")
      {:ok, text} = Render.tool_return(body, kind: "shell", head_lines: 3, tail_lines: 2)
      assert text =~ "head (lines 1–3):"
      assert text =~ "tail (lines 99–100):"
      assert text =~ "(95 lines omitted"
    end

    test "force_blob inlines via blob even for small output" do
      {:ok, text} = Render.tool_return("short\n", kind: "shell", force_blob: true)
      assert text =~ "blob:"
    end
  end

  describe "trace_return/1" do
    test "passes a structured output frame through unchanged" do
      frame = ~s(<output kind="shell" size="11" lines="1">\nhello world\n</output>)
      assert Render.trace_return(frame) == frame
    end

    test "returns short legacy text trimmed but intact" do
      short = "ok\nok\nok"
      assert Render.trace_return(short) == "ok\nok\nok"
    end

    test "folds long legacy text into head + omitted note + tail" do
      body = Enum.map_join(1..50, "\n", &"row #{&1}")
      rendered = Render.trace_return(body)

      assert rendered =~ "row 1"
      assert rendered =~ "row 6"
      refute rendered =~ "row 25"
      assert rendered =~ ~r/\(… \d+ lines omitted — read_tool_transcript for this cycle/
      assert rendered =~ "row 50"
    end
  end
end
