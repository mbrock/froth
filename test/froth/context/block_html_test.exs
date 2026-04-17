defmodule Froth.Context.BlockHTMLTest do
  use ExUnit.Case, async: true

  alias Froth.{Blobs, Repo}
  alias Froth.Context.{Block, BlockHTML, Blocks}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "live/1 — inline body" do
    test "a single block with a small body renders as its kind tag with attrs and body" do
      blocks =
        Blocks.materialize([
          Block.new([kind: "shell", task_id: "shell:abc", exit_code: 0], "hello world")
        ])

      html = BlockHTML.live_to_string(blocks)

      assert html =~ "<shell"
      assert html =~ ~s(task_id="shell:abc")
      assert html =~ ~s(exit_code="0")
      assert html =~ "hello world"
      refute html =~ "<head"
      refute html =~ "<tail"
    end

    test "text body with angle brackets is escaped by HEEx" do
      blocks = Blocks.materialize([Block.new([kind: "shell"], "grep '<script>' file")])
      html = BlockHTML.live_to_string(blocks)

      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end

    test "multiple blocks render in order" do
      blocks =
        Blocks.materialize([
          Block.new([kind: "io", session_id: "s1"], "io output"),
          Block.new([kind: "value", session_id: "s1"], "42")
        ])

      html = BlockHTML.live_to_string(blocks)
      io_pos = :binary.match(html, "io output") |> elem(0)
      val_pos = :binary.match(html, "42") |> elem(0)

      assert io_pos < val_pos
      assert html =~ "<io"
      assert html =~ "<value"
    end
  end

  describe "live/1 — folded body" do
    test "big bodies render with head/omitted/tail children backed by a blob" do
      big = Enum.map_join(1..80, "\n", &"line #{&1}")
      blocks = Blocks.materialize([Block.new([kind: "shell"], big)])

      html = BlockHTML.live_to_string(blocks)

      assert html =~ ~r/blob="[0-9A-HJKMNP-TV-Z]{26}"/
      assert html =~ "<head"
      assert html =~ "line 1"
      assert html =~ "line 10"
      assert html =~ "<omitted"
      assert html =~ ~s(count="65")
      assert html =~ "<tail"
      assert html =~ "line 80"
      refute html =~ "line 42"
    end

    test "the blob holds the full body" do
      big = Enum.map_join(1..100, "\n", &"row #{&1}")
      [block] = Blocks.materialize([Block.new([kind: "shell"], big)])

      blob_id = Block.attr(block, :blob)

      assert {:ok, blob} = Blobs.get(blob_id)
      assert blob.bytes == big
    end
  end

  describe "live/1 — metadata-only" do
    test "a block with no body renders self-closing with its attrs" do
      html =
        BlockHTML.live_to_string([
          Block.new(kind: "task", id: "shell:abc", status: "running", label: "tail -f")
        ])

      assert html =~ "<task"
      assert html =~ ~s(id="shell:abc")
      assert html =~ ~s(status="running")
      assert html =~ ~s(label="tail -f")
    end
  end

  describe "trace/1" do
    test "shows attrs plus a short preview, no head/tail split" do
      blocks =
        Blocks.materialize([Block.new([kind: "shell", task_id: "shell:abc"], "hello world")])

      %{blocks: blocks}
      |> BlockHTML.trace()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> tap(fn html ->
        assert html =~ "<shell"
        assert html =~ ~s(task_id="shell:abc")
        assert html =~ "hello world"
        refute html =~ "<head"
        refute html =~ "<tail"
        refute html =~ "<omitted"
      end)
    end

    test "truncates long preview to one line" do
      body = String.duplicate("x", 500) <> "\nmore stuff"
      blocks = Blocks.materialize([Block.new([kind: "shell"], body)])

      html =
        %{blocks: blocks}
        |> BlockHTML.trace()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      refute html =~ "more stuff"
    end
  end

  describe "safe tag names" do
    test "unsafe kind falls back to <block>" do
      # HTML void tags cannot be used as containers, so they fall back
      html = BlockHTML.live_to_string([Block.new([kind: "command"], "pwd")])
      assert html =~ "<block"
      refute html =~ "<command>"
    end

    test "malformed kind falls back to <block>" do
      html = BlockHTML.live_to_string([Block.new([kind: "not a tag!"], "x")])
      assert html =~ "<block"
    end
  end
end
