defmodule Froth.Inference.PagerToolTest do
  use ExUnit.Case, async: true

  alias Froth.{Blobs, Repo}
  alias Froth.Context.Block
  alias Froth.Inference.Tools

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    body = Enum.map_join(1..60, "\n", &"line #{&1}") <> "\n"
    {:ok, blob} = Blobs.put(body)
    {:ok, blob_id: blob.id, body: body}
  end

  describe "pager is registered in the tool catalog" do
    test "spec appears in specs_for_api/0" do
      names = Tools.specs_for_api() |> Enum.map(& &1["name"])
      assert "pager" in names
    end

    test "has a human label" do
      assert Tools.label("pager") == "pager"
    end
  end

  describe "pager tool execution" do
    defp call(input), do: Tools.execute("pager", input, 0, [])

    defp single_block!({:ok, [%Block{} = block]}), do: block

    test "mode=stat returns a metadata-only block", %{blob_id: id} do
      block = call(%{"id" => "blob:" <> id, "mode" => "stat"}) |> single_block!()

      assert Block.attr(block, :kind) == "stat"
      assert Block.attr(block, :blob) == id
      assert Block.attr(block, :lines) == 60
      assert Block.attr(block, :mime) == "text/plain"
      assert is_nil(block.body)
    end

    test "mode=head returns the first N lines in the body", %{blob_id: id} do
      block = call(%{"id" => id, "mode" => "head", "lines" => 3}) |> single_block!()

      assert Block.attr(block, :kind) == "head"
      assert block.body == "line 1\nline 2\nline 3"
    end

    test "mode=tail returns the last N lines in the body", %{blob_id: id} do
      block = call(%{"id" => id, "mode" => "tail", "lines" => 3}) |> single_block!()

      assert Block.attr(block, :kind) == "tail"
      assert block.body == "line 58\nline 59\nline 60"
    end

    test "mode=read returns a 1-indexed line range", %{blob_id: id} do
      block =
        call(%{"id" => id, "mode" => "read", "from_line" => 10, "lines" => 3})
        |> single_block!()

      assert Block.attr(block, :kind) == "page"
      assert Block.attr(block, :from_line) == 10
      assert block.body == "line 10\nline 11\nline 12"
    end

    test "mode=read default (no mode) starts from line 1", %{blob_id: id} do
      block = call(%{"id" => id, "lines" => 2}) |> single_block!()

      assert Block.attr(block, :from_line) == 1
      assert block.body =~ "line 1\nline 2"
    end

    test "mode=read past end marks the block empty", %{blob_id: id} do
      block =
        call(%{"id" => id, "mode" => "read", "from_line" => 999, "lines" => 3})
        |> single_block!()

      assert Block.attr(block, :empty) == true
      assert is_nil(block.body)
    end

    test "mode=grep returns a block with total/shown attrs and matches body", %{blob_id: id} do
      block =
        call(%{"id" => id, "mode" => "grep", "pattern" => "^line 1$"})
        |> single_block!()

      assert Block.attr(block, :kind) == "grep"
      assert Block.attr(block, :total) == 1
      assert Block.attr(block, :pattern) == "^line 1$"
      assert block.body =~ "line 1"
    end

    test "mode=grep with no matches returns a metadata-only block", %{blob_id: id} do
      block =
        call(%{"id" => id, "mode" => "grep", "pattern" => "unobtanium"})
        |> single_block!()

      assert Block.attr(block, :total) == 0
      assert is_nil(block.body)
    end

    test "mode=grep rejects empty or missing pattern", %{blob_id: id} do
      assert {:error, "grep requires a non-empty `pattern`"} =
               call(%{"id" => id, "mode" => "grep"})

      assert {:error, "grep requires a non-empty `pattern`"} =
               call(%{"id" => id, "mode" => "grep", "pattern" => ""})
    end

    test "mode=grep rejects invalid regex", %{blob_id: id} do
      assert {:error, msg} = call(%{"id" => id, "mode" => "grep", "pattern" => "("})
      assert msg =~ "invalid regex pattern"
    end

    test "invalid id returns a terse error" do
      assert {:error, "invalid blob id"} = call(%{"id" => "not-a-blob"})
    end

    test "missing blob returns not-found" do
      unknown = Ecto.ULID.generate()
      assert {:error, msg} = call(%{"id" => unknown, "mode" => "stat"})
      assert msg =~ "not found"
    end

    test "unknown mode returns an error", %{blob_id: id} do
      assert {:error, msg} = call(%{"id" => id, "mode" => "rewind"})
      assert msg =~ "unknown pager mode"
    end
  end
end
