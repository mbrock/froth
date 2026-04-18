defmodule Froth.Context.BlocksTest do
  use ExUnit.Case, async: true

  alias Froth.{Blobs, Repo}
  alias Froth.Context.{Block, Blocks}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "binary_shaped?/1" do
    test "blocks without :mime are text-shaped" do
      refute Blocks.binary_shaped?(Block.new([kind: "shell"], "hi"))
    end

    test "blocks with text/* mime are text-shaped" do
      refute Blocks.binary_shaped?(Block.new([kind: "page", mime: "text/markdown"], "# hi"))
      refute Blocks.binary_shaped?(Block.new([kind: "page", mime: "text/plain"], "hi"))
      refute Blocks.binary_shaped?(Block.new([kind: "page", mime: "text/html"], "<p>hi</p>"))
    end

    test "json/xml/javascript count as text-shaped" do
      refute Blocks.binary_shaped?(Block.new([kind: "data", mime: "application/json"], "{}"))
      refute Blocks.binary_shaped?(Block.new([kind: "data", mime: "application/xml"], "<x/>"))

      refute Blocks.binary_shaped?(
               Block.new([kind: "data", mime: "application/javascript"], "x=1")
             )
    end

    test "image/pdf/audio/video are binary-shaped" do
      assert Blocks.binary_shaped?(Block.new([kind: "img", mime: "image/jpeg"], <<>>))
      assert Blocks.binary_shaped?(Block.new([kind: "doc", mime: "application/pdf"], <<>>))
      assert Blocks.binary_shaped?(Block.new([kind: "audio", mime: "audio/ogg"], <<>>))
      assert Blocks.binary_shaped?(Block.new([kind: "video", mime: "video/mp4"], <<>>))
    end

    test "mime with parameters and case variations work" do
      assert Blocks.binary_shaped?(
               Block.new([kind: "img", mime: "Image/JPEG; charset=binary"], <<>>)
             )

      refute Blocks.binary_shaped?(
               Block.new([kind: "page", mime: "Text/Markdown; charset=utf-8"], "x")
             )
    end
  end

  describe "materialize/1 — text-shaped" do
    test "small bodies stay inline with size and lines attrs" do
      [block] = Blocks.materialize([Block.new([kind: "shell"], "hello world")])

      assert block.body == "hello world"
      assert Block.attr(block, :size) == 11
      assert Block.attr(block, :lines) == 1
      refute Block.attr(block, :blob)
    end

    test "big bodies are folded into blobs with head/tail/omitted attrs" do
      big = Enum.map_join(1..100, "\n", &"line #{&1}")
      [block] = Blocks.materialize([Block.new([kind: "shell"], big)])

      assert is_nil(block.body)
      assert is_binary(Block.attr(block, :blob))
      assert Block.attr(block, :lines) == 100
      assert length(Block.attr(block, :head)) == 10
      assert length(Block.attr(block, :tail)) == 5
      assert Block.attr(block, :omitted) == 85
    end
  end

  describe "materialize/1 — binary-shaped" do
    test "image body goes straight to a blob with no head/tail/lines" do
      bytes = :crypto.strong_rand_bytes(4096)

      [block] =
        Blocks.materialize([
          Block.new([kind: "fetched", mime: "image/jpeg", filename: "photo.jpg"], bytes)
        ])

      assert is_nil(block.body)
      assert Block.attr(block, :mime) == "image/jpeg"
      assert Block.attr(block, :filename) == "photo.jpg"
      assert Block.attr(block, :size) == 4096
      blob_id = Block.attr(block, :blob)
      assert is_binary(blob_id)

      refute Keyword.has_key?(block.attrs, :lines)
      refute Keyword.has_key?(block.attrs, :head)
      refute Keyword.has_key?(block.attrs, :tail)
      refute Keyword.has_key?(block.attrs, :omitted)

      {:ok, blob} = Blobs.get(blob_id)
      assert blob.bytes == bytes
      assert blob.mime == "image/jpeg"
    end

    test "small binary bodies still get blobbed (no size threshold for binary)" do
      [block] = Blocks.materialize([Block.new([kind: "img", mime: "image/png"], "tiny")])

      assert is_nil(block.body)
      assert is_binary(Block.attr(block, :blob))
      assert Block.attr(block, :size) == 4
    end

    test "binary block with :no_fold keeps the body inline" do
      bytes = :crypto.strong_rand_bytes(4096)

      [block] =
        Blocks.materialize([
          Block.new([kind: "img", mime: "image/jpeg", no_fold: true], bytes)
        ])

      assert block.body == bytes
      assert Block.attr(block, :size) == 4096
      refute Block.attr(block, :blob)
      refute Keyword.has_key?(block.attrs, :no_fold)
    end

    test "PDFs are binary-shaped, not text-folded" do
      pdf = "%PDF-1.4\n" <> :crypto.strong_rand_bytes(2000)

      [block] =
        Blocks.materialize([
          Block.new([kind: "fetched", mime: "application/pdf"], pdf)
        ])

      assert is_nil(block.body)
      assert is_binary(Block.attr(block, :blob))
      refute Keyword.has_key?(block.attrs, :head)
      refute Keyword.has_key?(block.attrs, :tail)
    end
  end

  describe "materialize/1 — children" do
    test "nested binary children are materialized recursively" do
      bytes = :crypto.strong_rand_bytes(1000)

      [parent] =
        Blocks.materialize([
          Block.new([kind: "fetched", url: "https://example.com"], nil, [
            Block.new([kind: "thumbnail", mime: "image/jpeg"], bytes)
          ])
        ])

      [child] = parent.children
      assert is_nil(child.body)
      assert is_binary(Block.attr(child, :blob))
      assert Block.attr(child, :size) == 1000
    end
  end
end
