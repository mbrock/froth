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

    test "blocks marked no_fold stay inline even when they exceed the default limits" do
      big = Enum.map_join(1..100, "\n", &"line #{&1}")

      [block] =
        Blocks.materialize([Block.new([kind: "page", blob: "01TEST", no_fold: true], big)])

      assert is_binary(block.body)
      assert Block.attr(block, :blob) == "01TEST"
      refute Block.attr(block, :blob) =~ ~r/\A[0-9A-HJKMNP-TV-Z]{26}\z/
      refute Keyword.has_key?(block.attrs, :no_fold)
      refute Keyword.has_key?(block.attrs, :head)
      refute Keyword.has_key?(block.attrs, :tail)
    end
  end

  describe "live/1 — folded body" do
    test "big bodies render with head/omitted/tail children backed by a blob" do
      big = Enum.map_join(1..100, "\n", &"line #{&1}")
      blocks = Blocks.materialize([Block.new([kind: "shell"], big)])

      html = BlockHTML.live_to_string(blocks)

      assert html =~ ~r/blob="[0-9A-HJKMNP-TV-Z]{26}"/
      assert html =~ "<head"
      assert html =~ "line 1"
      assert html =~ "line 10"
      assert html =~ "<omitted"
      assert html =~ ~s(count="85")
      assert html =~ "<tail"
      assert html =~ "line 100"
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

    test "nested child blocks render inside their parent block" do
      html =
        BlockHTML.live_to_string([
          Block.new(
            [kind: "timeline", id: "window-1"],
            nil,
            [
              Block.new([kind: "text", id: "tg:1"], "hello"),
              Block.new([kind: "analysis", id: 12], "short summary")
            ]
          )
        ])

      assert html =~ ~s(<timeline id="window-1")
      assert html =~ ~s(<text id="tg:1")
      assert html =~ "hello"
      assert html =~ ~s(<analysis id="12")
      assert html =~ "short summary"
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

    test "shows a compact multi-line preview with a continuation summary" do
      body =
        [
          String.duplicate("x", 500),
          "more stuff",
          "third line",
          "fourth line"
        ]
        |> Enum.join("\n")

      blocks = Blocks.materialize([Block.new([kind: "shell"], body)])

      html =
        %{blocks: blocks}
        |> BlockHTML.trace()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "more stuff"
      assert html =~ "third line"
      refute html =~ "fourth line"
      assert html =~ "... 1 more line"
    end

    test "folded blocks show multiple preview lines and a continuation summary" do
      body = Enum.map_join(1..100, "\n", &"line #{&1}")
      blocks = Blocks.materialize([Block.new([kind: "shell"], body)])

      html =
        %{blocks: blocks}
        |> BlockHTML.trace()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "line 1"
      assert html =~ "line 2"
      assert html =~ "line 3"
      assert html =~ "... 97 more lines"
      refute html =~ "<head"
      refute html =~ "<tail"
      refute html =~ "<omitted"
    end

    test "renders nested child blocks in trace output" do
      blocks =
        Blocks.materialize([
          Block.new(
            [kind: "timeline", id: "window-1"],
            nil,
            [Block.new([kind: "text", id: "tg:1"], "hello world")]
          )
        ])

      html =
        %{blocks: blocks}
        |> BlockHTML.trace()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ ~s(<timeline id="window-1")
      assert html =~ ~s(<text id="tg:1")
      assert html =~ "hello world"
    end
  end

  describe "live/1 — binary-shaped" do
    test "image block renders as a placeholder tag with mime/blob/filename, no body" do
      bytes = :crypto.strong_rand_bytes(8192)

      blocks =
        Blocks.materialize([
          Block.new(
            [kind: "fetched", mime: "image/jpeg", filename: "cat.jpg", source: "msg:42"],
            bytes
          )
        ])

      html = BlockHTML.live_to_string(blocks)

      assert html =~ "<fetched"
      assert html =~ ~s(mime="image/jpeg")
      assert html =~ ~s(filename="cat.jpg")
      assert html =~ ~s(source="msg:42")
      assert html =~ ~r/blob="[0-9A-HJKMNP-TV-Z]{26}"/
      assert html =~ ~s(size="8192")
      refute html =~ "<head"
      refute html =~ "<tail"
      refute html =~ "<omitted"
    end

    test "image block with :no_fold also renders as placeholder, body not inlined" do
      bytes = "fake-image-bytes-with-some-pseudo-binary"

      blocks =
        Blocks.materialize([
          Block.new(
            [kind: "image", mime: "image/png", filename: "x.png", no_fold: true],
            bytes
          )
        ])

      html = BlockHTML.live_to_string(blocks)

      assert html =~ "<image"
      assert html =~ ~s(mime="image/png")
      assert html =~ ~s(filename="x.png")
      refute html =~ "fake-image-bytes"
    end

    test "binary-shaped block body carries a visible [binary: …] placeholder" do
      # Simulates the `cat foo.png` path: a text-shaped shell block
      # comes in with raw PNG bytes, gets auto-promoted to binary,
      # and renders with an inline placeholder so the agent can tell
      # "there's a PNG here" from "cat produced nothing".
      png = <<0x89, "PNG\r\n", 0x1A, 0x0A>> <> :crypto.strong_rand_bytes(10_000)

      blocks =
        Blocks.materialize([
          Block.new([kind: "shell", task_id: "shell:abc", exit_code: 0], png)
        ])

      html = BlockHTML.live_to_string(blocks)
      [block] = blocks
      expected_size = Block.attr(block, :size)
      expected_blob = Block.attr(block, :blob)

      assert html =~ ~s(mime="image/png")
      assert html =~ "[binary: image/png #{expected_size} bytes → blob:#{expected_blob}]"
    end

    test "binary placeholder falls back to octet-stream when mime is unknown" do
      bytes = :crypto.strong_rand_bytes(256)

      blocks =
        Blocks.materialize([
          Block.new([kind: "shell"], <<0xAB, 0xCD, 0xEF, 0x00, 0x01>> <> bytes)
        ])

      html = BlockHTML.live_to_string(blocks)

      assert html =~ "[binary: application/octet-stream"
      assert html =~ ~r/bytes → blob:[0-9A-HJKMNP-TV-Z]{26}\]/
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
