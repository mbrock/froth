defmodule Froth.AnthropicTest do
  use Froth.AnthropicCase, async: false

  alias Froth.Anthropic

  describe "stream_single/3 with simple text fixture" do
    test "returns text and usage" do
      Application.put_env(:froth, :sse_stream_fun, Froth.SSEReplay.stream_fun("simple_reply"))

      {:ok, %{text: text, content: content, stop_reason: stop_reason, usage: usage}} =
        Anthropic.stream_single(
          [%{"role" => "user", "content" => "hello"}],
          fn _event -> :ok end
        )

      assert text =~ "transistor"
      assert text =~ "1947"
      assert is_list(content)
      assert stop_reason == "end_turn"
      assert usage["input_tokens"] == 18
      assert usage["output_tokens"] == 36
    end

    test "emits text_delta events" do
      Application.put_env(:froth, :sse_stream_fun, Froth.SSEReplay.stream_fun("simple_reply"))

      pid = self()

      {:ok, _} =
        Anthropic.stream_single(
          [%{"role" => "user", "content" => "hello"}],
          fn event -> send(pid, {:event, event}) end
        )

      deltas = collect_events(:text_delta)
      assert length(deltas) > 0
      full_text = deltas |> Enum.map(fn {:text_delta, t} -> t end) |> Enum.join()
      assert full_text =~ "transistor"
    end
  end

  describe "stream_single/3 with thinking fixture" do
    test "processes thinking blocks and returns text" do
      Application.put_env(:froth, :sse_stream_fun, Froth.SSEReplay.stream_fun("thinking_reply"))

      pid = self()

      {:ok, %{text: text, content: content}} =
        Anthropic.stream_single(
          [%{"role" => "user", "content" => "what is 2+2?"}],
          fn event -> send(pid, {:event, event}) end
        )

      assert text =~ "2 + 2"
      assert is_list(content)
      assert Enum.any?(content, &(&1["type"] == "thinking"))
      assert Enum.any?(content, &(&1["type"] == "text"))

      assert_received {:event, {:thinking_start, %{"index" => 0}}}
      assert_received {:event, {:thinking_stop, %{"index" => 0, "thinking" => thinking}}}
      assert thinking =~ "2"
    end
  end

  describe "prompt caching payload passthrough" do
    test "sends top-level cache_control and preserves content blocks" do
      pid = self()

      Application.put_env(
        :froth,
        :sse_stream_fun,
        Froth.SSEReplay.recording_stream_fun("simple_reply", pid)
      )

      messages = [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => "<cached_context>stable</cached_context>",
              "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
            },
            %{"type" => "text", "text" => "\n<dynamic>new message</dynamic>"}
          ]
        }
      ]

      {:ok, _result} =
        Anthropic.stream_single(messages, fn _event -> :ok end)

      assert_received {:api_call, 0, body}
      assert body["cache_control"] == %{"type" => "ephemeral"}
      content_blocks = get_in(body, ["messages", Access.at(0), "content"])

      assert [
               %{
                 "type" => "text",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               },
               %{"type" => "text"}
             ] = content_blocks
    end
  end

  describe "max_tokens config" do
    test "sends configured max_tokens to Anthropic" do
      pid = self()

      Application.put_env(
        :froth,
        :sse_stream_fun,
        Froth.SSEReplay.recording_stream_fun("simple_reply", pid)
      )

      Application.put_env(:froth, Froth.Anthropic,
        api_key: "test-key-not-real",
        model: "claude-opus-4-6",
        max_tokens: 16_384
      )

      {:ok, _result} =
        Anthropic.stream_single(
          [%{"role" => "user", "content" => "hello"}],
          fn _event -> :ok end
        )

      assert_received {:api_call, 0, body}
      assert body["max_tokens"] == 16_384
    end
  end

  describe "missing API key" do
    test "returns error when no API key configured" do
      Application.put_env(:froth, Froth.Anthropic,
        api_key: nil,
        model: "claude-opus-4-6"
      )

      assert {:error, :missing_api_key} =
               Anthropic.stream_single(
                 [%{"role" => "user", "content" => "test"}],
                 fn _ -> :ok end
               )
    end
  end

  defp collect_events(type) do
    collect_events(type, [])
  end

  defp collect_events(type, acc) do
    receive do
      {:event, {^type, _} = event} -> collect_events(type, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
