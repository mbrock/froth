defmodule Froth.AnthropicTest do
  use Froth.AnthropicCase, async: false

  alias Froth.Anthropic
  alias Froth.LLM.Message

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

  describe "shared message normalization" do
    test "encodes Froth.LLM.Message structs before sending Anthropic requests" do
      pid = self()

      Application.put_env(
        :froth,
        :sse_stream_fun,
        Froth.SSEReplay.recording_stream_fun("simple_reply", pid)
      )

      messages = [
        Message.user("hello"),
        Message.assistant([
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "froth_echo",
            "input" => %{"text" => "hi"}
          }
        ]),
        Message.user([
          %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => "echoed: hi"}
        ])
      ]

      assert {:ok, _result} = Anthropic.stream_single(messages, fn _event -> :ok end)

      assert_received {:api_call, 0, body}

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]},
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "call_1",
                     "name" => "froth_echo",
                     "input" => %{"text" => "hi"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "call_1",
                     "content" => "echoed: hi"
                   }
                 ]
               }
             ]
    end
  end

  describe "mcp connector request wiring" do
    test "adds the MCP beta header and encodes remote MCP endpoints" do
      pid = self()

      Application.put_env(:froth, :sse_stream_fun, fn _url, headers, body, _on_event ->
        send(pid, {:api_call_headers, headers})
        send(pid, {:api_call_body, body})

        Froth.SSEReplay.replay_fixture(fixture_path("simple_reply/turn_0.sse"), fn _event ->
          :ok
        end)
      end)

      {:ok, _result} =
        Anthropic.stream_single(
          [%{"role" => "user", "content" => "hello"}],
          fn _event -> :ok end,
          tools: [
            %{
              "type" => "mcp_endpoint",
              "name" => "wolfram",
              "url" => "https://services.wolfram.com/api/mcp",
              "bearer_token" => "wolfram-token",
              "defer_loading" => true
            }
          ]
        )

      assert_receive {:api_call_headers, headers}
      assert_receive {:api_call_body, body}

      assert {"anthropic-beta", beta_header} =
               Enum.find(headers, fn {name, _value} -> name == "anthropic-beta" end)

      assert beta_header =~ "context-1m-2025-08-07"
      assert beta_header =~ "mcp-client-2025-11-20"

      assert body["mcp_servers"] == [
               %{
                 "type" => "url",
                 "url" => "https://services.wolfram.com/api/mcp",
                 "name" => "wolfram",
                 "authorization_token" => "wolfram-token"
               }
             ]

      assert body["tools"] == [
               %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "wolfram",
                 "default_config" => %{"defer_loading" => true}
               }
             ]
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

  describe "provider errors" do
    test "returns streamed provider errors instead of an empty success" do
      Application.put_env(:froth, :sse_stream_fun, Froth.SSEReplay.stream_fun("error_reply"))

      assert {:error, {:provider_error, "anthropic", error, _diagnostics}} =
               Anthropic.stream_single(
                 [%{"role" => "user", "content" => "hello"}],
                 fn _event -> :ok end,
                 max_retries: 0
               )

      assert get_in(error, ["error", "type"]) == "overloaded_error"
      assert get_in(error, ["error", "message"]) == "Overloaded"
    end

    test "retries transient api_error responses" do
      pid = self()
      counter = :counters.new(1, [:atomics])

      Application.put_env(:froth, :sse_stream_fun, fn _url, _headers, _body, _on_event ->
        turn = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        send(pid, {:attempt, turn})

        case turn do
          0 ->
            {:error,
             {:provider_error, "anthropic",
              %{
                "error" => %{
                  "message" => "Internal server error",
                  "type" => "api_error"
                }
              }, %{}}}

          _ ->
            Froth.SSEReplay.replay_fixture(fixture_path("simple_reply/turn_0.sse"), fn _event ->
              :ok
            end)
        end
      end)

      assert {:ok, %{text: text}} =
               Anthropic.stream_single(
                 [%{"role" => "user", "content" => "hello"}],
                 fn _event -> :ok end,
                 retry_base_ms: 0,
                 retry_max_ms: 0
               )

      assert text =~ "transistor"
      assert_receive {:attempt, 0}
      assert_receive {:attempt, 1}
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

  defp fixture_path(name), do: Path.join([__DIR__, "..", "fixtures", "sse", name])
end
