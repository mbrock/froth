defmodule Froth.Agent.ToolResultTest do
  use ExUnit.Case, async: true

  alias Froth.{Repo}
  alias Froth.Agent.ToolResult
  alias Froth.Context.{Block, Blocks}

  test "to_api preserves structured content blocks with string keys" do
    result =
      ToolResult.new("call_1", [
        %{"type" => "text", "text" => "done"},
        %{
          type: "image",
          source: %{
            type: "base64",
            media_type: "image/png",
            data: "aGVsbG8="
          }
        }
      ])

    assert ToolResult.to_api(result) == %{
             "type" => "tool_result",
             "tool_use_id" => "call_1",
             "content" => [
               %{"type" => "text", "text" => "done"},
               %{
                 "type" => "image",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "image/png",
                   "data" => "aGVsbG8="
                 }
               }
             ]
           }
  end

  describe "to_api with %Block{} lists" do
    setup do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    test "all-text block list collapses to a single string content" do
      blocks = Blocks.materialize([Block.new([kind: "shell"], "hello world")])
      result = ToolResult.new("call_1", blocks)
      api = ToolResult.to_api(result)

      assert is_binary(api["content"])
      assert api["content"] =~ "<shell"
      assert api["content"] =~ "hello world"
    end

    test "explicit pager reads stay inline in the API content" do
      body =
        Enum.map_join(1..241, "\n", fn line ->
          "line #{line} #{String.duplicate("x", 80)}"
        end)

      blocks =
        Blocks.materialize([
          Block.new(
            [
              kind: "page",
              blob: "01K00000000000000000000000",
              from_line: 1,
              lines_requested: 241,
              no_fold: true
            ],
            body
          )
        ])

      result = ToolResult.new("call_1", blocks)
      api = ToolResult.to_api(result)

      assert is_binary(api["content"])
      assert api["content"] =~ "line 1 "
      assert api["content"] =~ "line 241 "
      refute api["content"] =~ "<omitted"
      refute api["content"] =~ "use pager to read more"
    end

    test "block list with a binary block becomes [text, image] content parts" do
      bytes = :crypto.strong_rand_bytes(2048)

      blocks =
        Blocks.materialize([
          Block.new(
            [kind: "fetched", mime: "image/jpeg", filename: "cat.jpg"],
            bytes
          )
        ])

      result = ToolResult.new("call_2", blocks)
      api = ToolResult.to_api(result)

      assert [text_part, image_part] = api["content"]

      assert text_part["type"] == "text"
      assert text_part["text"] =~ "<fetched"
      assert text_part["text"] =~ ~s(mime="image/jpeg")

      assert image_part["type"] == "image"
      assert image_part["source"]["type"] == "base64"
      assert image_part["source"]["media_type"] == "image/jpeg"
      assert image_part["source"]["data"] == Base.encode64(bytes)
    end

    test "PDF blocks become document content parts" do
      pdf = "%PDF-1.4\n" <> :crypto.strong_rand_bytes(1024)

      blocks =
        Blocks.materialize([
          Block.new([kind: "fetched", mime: "application/pdf"], pdf)
        ])

      result = ToolResult.new("call_3", blocks)
      api = ToolResult.to_api(result)

      assert [_text_part, doc_part] = api["content"]
      assert doc_part["type"] == "document"
      assert doc_part["source"]["media_type"] == "application/pdf"
      assert doc_part["source"]["data"] == Base.encode64(pdf)
    end

    test "binary blocks nested in children also surface as media parts" do
      bytes = :crypto.strong_rand_bytes(512)

      blocks =
        Blocks.materialize([
          Block.new([kind: "wrapper"], nil, [
            Block.new([kind: "image", mime: "image/png"], bytes)
          ])
        ])

      result = ToolResult.new("call_4", blocks)
      api = ToolResult.to_api(result)

      assert [text_part, image_part] = api["content"]
      assert text_part["text"] =~ "<wrapper"
      assert text_part["text"] =~ "<image"
      assert image_part["type"] == "image"
      assert image_part["source"]["data"] == Base.encode64(bytes)
    end

    test "multiple binary blocks come out in document order" do
      bytes_a = :crypto.strong_rand_bytes(256)
      bytes_b = :crypto.strong_rand_bytes(256)

      blocks =
        Blocks.materialize([
          Block.new(
            [kind: "image", mime: "image/jpeg", filename: "a.jpg"],
            bytes_a
          ),
          Block.new(
            [kind: "image", mime: "image/jpeg", filename: "b.jpg"],
            bytes_b
          )
        ])

      result = ToolResult.new("call_5", blocks)
      api = ToolResult.to_api(result)

      assert [_text, part_a, part_b] = api["content"]
      assert part_a["source"]["data"] == Base.encode64(bytes_a)
      assert part_b["source"]["data"] == Base.encode64(bytes_b)
    end

    test "block with non-image/non-pdf mime is described in text but no media part emitted" do
      bytes = :crypto.strong_rand_bytes(256)

      blocks =
        Blocks.materialize([
          Block.new(
            [kind: "audio", mime: "audio/ogg", filename: "voice.ogg"],
            bytes
          )
        ])

      result = ToolResult.new("call_6", blocks)
      api = ToolResult.to_api(result)

      assert is_binary(api["content"])
      assert api["content"] =~ "<audio"
      assert api["content"] =~ ~s(mime="audio/ogg")
    end
  end
end
