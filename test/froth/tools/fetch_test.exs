defmodule Froth.Tools.FetchTest do
  use ExUnit.Case, async: false

  alias Froth.Agent.{
    CycleRuntime.Context,
    CycleRuntime.View,
    Surface,
    ToolUse
  }

  alias Froth.Context.Block
  alias Froth.Tools.Fetch
  alias Req.Test, as: ReqTest

  setup do
    previous_req_defaults = Req.default_options()
    on_exit(fn -> Req.default_options(previous_req_defaults) end)
    :ok
  end

  describe "source parsing" do
    test "missing source returns a helpful error" do
      assert {:error, msg} = Fetch.execute(empty_context(), tool_use(%{}), [])
      assert msg =~ "Missing source"
    end

    test "blank source returns a helpful error" do
      assert {:error, msg} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "   "}),
                 []
               )

      assert msg =~ "Missing source"
    end

    test "garbage source returns a helpful error" do
      assert {:error, msg} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "not-a-url-or-msg"}),
                 []
               )

      assert msg =~ "Invalid source"
    end

    test "telegram source without a chat returns a clear error" do
      assert {:error, msg} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "msg:42"}),
                 []
               )

      assert msg =~ "Telegram source requires"
    end

    test "negative integer is rejected" do
      assert {:error, msg} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "-1"}),
                 []
               )

      assert msg =~ "Invalid source"
    end

    test "legacy message_id key still works (backwards-compat)" do
      # Without a session, we expect the post-parse "Telegram source requires…" error,
      # which proves the parser accepted message_id as a fallback.
      assert {:error, msg} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"message_id" => 12_345}),
                 []
               )

      assert msg =~ "Telegram source requires"
    end
  end

  describe "URL fetch — non-HTML (direct Req)" do
    test "HEAD with image/png routes to Req.get and returns a binary fetched block" do
      png_bytes =
        <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64)

      stub = stub_url("https://example.test/cat.png", png_bytes, "image/png")

      Req.default_options(plug: {ReqTest, stub})

      assert {:ok, [%Block{} = block]} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "https://example.test/cat.png"}),
                 []
               )

      assert Block.attr(block, :kind) == "fetched"
      assert Block.attr(block, :mime) == "image/png"
      assert Block.attr(block, :source) == "https://example.test/cat.png"
      assert Block.attr(block, :filename) == "cat.png"
      assert Block.attr(block, :size) == byte_size(png_bytes)
      assert Block.attr(block, :public_url) =~ "/files/"
      assert Block.attr(block, :local_path) =~ "/priv/static/files/"
      assert block.body == png_bytes

      File.rm(Block.attr(block, :local_path))
    end

    test "HEAD with application/pdf routes to Req.get; defaults to view: false (no body)" do
      pdf = "%PDF-1.4\n" <> :crypto.strong_rand_bytes(128)
      stub = stub_url("https://example.test/spec.pdf", pdf, "application/pdf")

      Req.default_options(plug: {ReqTest, stub})

      assert {:ok, [%Block{} = block]} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "https://example.test/spec.pdf"}),
                 []
               )

      assert Block.attr(block, :mime) == "application/pdf"
      assert Block.attr(block, :filename) == "spec.pdf"
      assert is_nil(block.body)

      File.rm(Block.attr(block, :local_path))
    end

    test "PDF with explicit view: true inlines the body" do
      pdf = "%PDF-1.4\n" <> :crypto.strong_rand_bytes(128)

      stub =
        stub_url("https://example.test/inlined.pdf", pdf, "application/pdf")

      Req.default_options(plug: {ReqTest, stub})

      assert {:ok, [%Block{} = block]} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{
                   "source" => "https://example.test/inlined.pdf",
                   "view" => true
                 }),
                 []
               )

      assert block.body == pdf

      File.rm(Block.attr(block, :local_path))
    end

    test "view: false returns a metadata-only block (no body)" do
      bytes = :crypto.strong_rand_bytes(256)

      stub =
        stub_url(
          "https://example.test/blob.bin",
          bytes,
          "application/octet-stream"
        )

      Req.default_options(plug: {ReqTest, stub})

      assert {:ok, [%Block{} = block]} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{
                   "source" => "https://example.test/blob.bin",
                   "view" => false
                 }),
                 []
               )

      assert is_nil(block.body)
      assert Block.attr(block, :public_url) =~ "/files/"
      assert Block.attr(block, :size) == 256

      File.rm(Block.attr(block, :local_path))
    end

    test "HEAD 405 with text/html on an actual image still routes correctly via GET fallback" do
      # Many sites (HN among them) return 405 Method Not Allowed for
      # HEAD with content-type: text/html (the error page's type).
      # We must NOT trust that and route to lightpanda — the actual
      # resource here is a PNG and we should get its raw bytes back.
      png_bytes =
        <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64)

      stub_name = {:fetch_405_then_png, System.unique_integer([:positive])}

      ReqTest.stub(stub_name, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/html")
            |> Plug.Conn.send_resp(405, "")

          "GET" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "image/png")
            |> Plug.Conn.send_resp(200, png_bytes)
        end
      end)

      Req.default_options(plug: {ReqTest, stub_name})

      assert {:ok, [%Block{} = block]} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{
                   "source" => "https://example.test/disguised.png"
                 }),
                 []
               )

      assert Block.attr(block, :mime) == "image/png"
      assert block.body == png_bytes

      File.rm(Block.attr(block, :local_path))
    end

    test "HEAD 405 + GET text/html falls back to lightpanda" do
      # The other half of the previous case: a 405 HEAD shouldn't
      # commit us to the GET body when the resource genuinely IS
      # HTML — we should still re-route through lightpanda for
      # markdown rendering. Since invoking the real lightpanda binary
      # in a unit test isn't desirable, we just assert that the
      # routing reaches an :error from the (presumably absent or
      # network-blocked) lightpanda binary; the important thing is
      # that we did NOT end up with the raw HTML body inlined as the
      # block's content.
      stub_name = {:fetch_405_then_html, System.unique_integer([:positive])}

      ReqTest.stub(stub_name, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/html")
            |> Plug.Conn.send_resp(405, "")

          "GET" ->
            conn
            |> Plug.Conn.put_resp_header(
              "content-type",
              "text/html; charset=utf-8"
            )
            |> Plug.Conn.send_resp(
              200,
              "<!doctype html><body>real html</body>"
            )
        end
      end)

      Req.default_options(plug: {ReqTest, stub_name})

      result =
        Fetch.execute(
          empty_context(),
          tool_use(%{"source" => "https://example.test/page"}),
          []
        )

      # Either lightpanda renders successfully (and we get markdown)
      # or its invocation fails — but in no case should the raw HTML
      # body leak through as the block's content.
      case result do
        {:ok, [%Block{} = block]} ->
          assert Block.attr(block, :mime) == "text/markdown"
          refute block.body && block.body =~ "<!doctype html"
          File.rm(Block.attr(block, :local_path))

        {:error, msg} ->
          assert is_binary(msg)
          assert msg =~ "lightpanda"
      end
    end

    test "non-2xx response returns a clear error" do
      stub_name = {:fetch_404, System.unique_integer([:positive])}

      ReqTest.stub(stub_name, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.send_resp(404, "")

          "GET" ->
            Plug.Conn.send_resp(conn, 404, "missing")
        end
      end)

      Req.default_options(plug: {ReqTest, stub_name})

      assert {:error, msg} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "https://example.test/missing"}),
                 []
               )

      assert msg =~ "404"
    end
  end

  describe "URL fetch — filename derivation" do
    test "URL with no filename in path falls back to a hostname-based name" do
      bytes = :crypto.strong_rand_bytes(64)
      stub = stub_url("https://example.test/", bytes, "image/jpeg")

      Req.default_options(plug: {ReqTest, stub})

      assert {:ok, [%Block{} = block]} =
               Fetch.execute(
                 empty_context(),
                 tool_use(%{"source" => "https://example.test/"}),
                 []
               )

      assert Block.attr(block, :filename) =~ "example-test"
      assert Block.attr(block, :filename) =~ ".jpg"

      File.rm(Block.attr(block, :local_path))
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp empty_context do
    %Context{
      cycle_id: "test-cycle",
      cycle: nil,
      bot_config: nil,
      surface: %Surface{session_id: nil, chat_id: nil, reply_to: nil},
      view: %View{active_task_ids: []},
      spam: false,
      system_prompt: nil,
      tool_specs: []
    }
  end

  defp tool_use(input) do
    %ToolUse{id: "test-call", name: "fetch", input: input}
  end

  defp stub_url(url, body, content_type) do
    stub_name = {:fetch_url_stub, System.unique_integer([:positive])}

    %URI{path: path} = URI.parse(url)
    expected_path = if path in [nil, ""], do: "/", else: path

    ReqTest.stub(stub_name, fn conn ->
      assert conn.request_path == expected_path

      conn
      |> Plug.Conn.put_resp_header("content-type", content_type)
      |> case do
        c when conn.method == "HEAD" -> Plug.Conn.send_resp(c, 200, "")
        c when conn.method == "GET" -> Plug.Conn.send_resp(c, 200, body)
      end
    end)

    stub_name
  end
end
