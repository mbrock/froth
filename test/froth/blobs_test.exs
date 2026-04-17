defmodule Froth.BlobsTest do
  use ExUnit.Case, async: true

  alias Froth.{Blob, Blobs, Repo}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "put/2" do
    test "stores a text body and computes size + line count" do
      body = "alpha\nbeta\ngamma\n"

      assert {:ok, %Blob{} = blob} = Blobs.put(body)
      assert blob.bytes == body
      assert blob.mime == "text/plain"
      assert blob.size == byte_size(body)
      assert blob.lines == 3
      assert is_binary(blob.id) and byte_size(blob.id) == 26
    end

    test "accepts an explicit mime and skips line counting for non-textual mimes" do
      body = <<0, 1, 2, 3, 4>>
      assert {:ok, blob} = Blobs.put(body, mime: "application/octet-stream")
      assert blob.mime == "application/octet-stream"
      assert blob.size == 5
      assert blob.lines == nil
    end

    test "a blob without a trailing newline still counts the last line" do
      {:ok, blob} = Blobs.put("one\ntwo\nthree")
      assert blob.lines == 3
    end
  end

  describe "id handling" do
    test "normalize_id accepts bare ULID or `blob:`-prefixed form" do
      {:ok, blob} = Blobs.put("x")
      blob_id = blob.id
      assert {:ok, ^blob_id} = Blobs.normalize_id(blob.id)
      assert {:ok, ^blob_id} = Blobs.normalize_id("blob:" <> blob.id)
      assert {:ok, ^blob_id} = Blobs.normalize_id("  blob:" <> String.downcase(blob.id) <> "  ")
    end

    test "rejects garbage" do
      assert {:error, :invalid_id} = Blobs.normalize_id("nope")
      assert {:error, :invalid_id} = Blobs.normalize_id(123)
    end

    test "get returns :not_found for a well-formed but absent id" do
      assert {:error, :not_found} = Blobs.get(Ecto.ULID.generate())
    end
  end

  describe "stat/1" do
    test "returns metadata without loading bytes" do
      {:ok, blob} = Blobs.put("alpha\nbeta\n")
      assert {:ok, stat} = Blobs.stat(blob.id)
      assert stat.id == blob.id
      assert stat.mime == "text/plain"
      assert stat.size == byte_size("alpha\nbeta\n")
      assert stat.lines == 2
      assert match?(%DateTime{}, stat.inserted_at)
    end
  end

  describe "head/2 and tail/2" do
    setup do
      body = Enum.map_join(1..20, "\n", &"line #{&1}") <> "\n"
      {:ok, blob} = Blobs.put(body)
      {:ok, id: blob.id, body: body}
    end

    test "head returns the first N lines", %{id: id} do
      assert {:ok, "line 1\nline 2\nline 3"} = Blobs.head(id, 3)
    end

    test "tail returns the last N lines", %{id: id} do
      assert {:ok, "line 18\nline 19\nline 20"} = Blobs.tail(id, 3)
    end

    test "head/tail with N ≥ total returns everything", %{id: id, body: body} do
      trimmed = String.trim_trailing(body, "\n")
      assert {:ok, ^trimmed} = Blobs.head(id, 100)
      assert {:ok, ^trimmed} = Blobs.tail(id, 100)
    end
  end

  describe "page/2" do
    test "returns a 1-indexed line range" do
      body = Enum.map_join(1..10, "\n", &"row #{&1}") <> "\n"
      {:ok, blob} = Blobs.put(body)

      assert {:ok, "row 4\nrow 5\nrow 6"} = Blobs.page(blob.id, from_line: 4, lines: 3)
    end

    test "past the end returns empty" do
      {:ok, blob} = Blobs.put("a\nb\n")
      assert {:ok, ""} = Blobs.page(blob.id, from_line: 100, lines: 10)
    end
  end

  describe "grep/3" do
    test "returns line-numbered matches with trailing context" do
      body = """
      one
      two matches here
      three
      four
      five two matches
      six
      """

      {:ok, blob} = Blobs.put(body)
      assert {:ok, result} = Blobs.grep(blob.id, "two", before: 0, after: 1)
      assert result.total_matches == 2
      assert result.shown == 2
      assert result.text =~ "two matches here"
      assert result.text =~ "five two matches"
      # --- separator between disjoint context windows
      assert result.text =~ "--"
    end

    test "no matches yields a terse sentinel" do
      {:ok, blob} = Blobs.put("nothing to see\nkeep walking\n")
      assert {:ok, %{total_matches: 0, text: "(no matches)"}} = Blobs.grep(blob.id, "absent")
    end

    test "caps matches with :max" do
      body = Enum.map_join(1..100, "\n", fn _ -> "hit" end)
      {:ok, blob} = Blobs.put(body)
      assert {:ok, result} = Blobs.grep(blob.id, "hit", max: 5, after: 0)
      assert result.total_matches == 100
      assert result.shown == 5
    end

    test "rejects invalid patterns" do
      {:ok, blob} = Blobs.put("x")
      assert {:error, {:invalid_pattern, _}} = Blobs.grep(blob.id, "(")
    end
  end
end
