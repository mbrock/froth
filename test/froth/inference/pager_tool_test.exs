defmodule Froth.Inference.PagerToolTest do
  use ExUnit.Case, async: true

  alias Froth.{Blobs, Repo}
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
    # Use the 4-ary shim (no real chat/ctx needed for pager).
    defp call(input), do: Tools.execute("pager", input, 0, [])

    test "mode=stat returns metadata", %{blob_id: id} do
      assert {:ok, stat_text} = call(%{"id" => "blob:" <> id, "mode" => "stat"})
      assert stat_text =~ "blob:#{id}"
      assert stat_text =~ "60 lines"
      assert stat_text =~ "mime=text/plain"
    end

    test "mode=head returns the first N lines", %{blob_id: id} do
      assert {:ok, text} = call(%{"id" => id, "mode" => "head", "lines" => 3})
      assert text == "line 1\nline 2\nline 3"
    end

    test "mode=tail returns the last N lines", %{blob_id: id} do
      assert {:ok, text} = call(%{"id" => id, "mode" => "tail", "lines" => 3})
      assert text == "line 58\nline 59\nline 60"
    end

    test "mode=read returns a 1-indexed line range", %{blob_id: id} do
      assert {:ok, text} =
               call(%{"id" => id, "mode" => "read", "from_line" => 10, "lines" => 3})

      assert text == "line 10\nline 11\nline 12"
    end

    test "mode=read default (no mode) starts from line 1", %{blob_id: id} do
      assert {:ok, text} = call(%{"id" => id, "lines" => 2})
      assert text =~ "line 1\nline 2"
    end

    test "mode=read past end returns an explicit marker", %{blob_id: id} do
      assert {:ok, "(empty range — past end of blob)"} =
               call(%{"id" => id, "mode" => "read", "from_line" => 999, "lines" => 3})
    end

    test "mode=grep returns matches with line numbers", %{blob_id: id} do
      assert {:ok, text} = call(%{"id" => id, "mode" => "grep", "pattern" => "^line 1$"})
      assert text =~ "1 matches"
      assert text =~ "line 1"
    end

    test "mode=grep sentinel when no matches", %{blob_id: id} do
      assert {:ok, "(no matches for pattern)"} =
               call(%{"id" => id, "mode" => "grep", "pattern" => "unobtanium"})
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
