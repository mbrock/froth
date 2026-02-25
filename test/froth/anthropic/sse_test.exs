defmodule Froth.Anthropic.SSETest do
  use ExUnit.Case, async: true

  alias Froth.Anthropic.SSE

  describe "split_frames/1" do
    test "separates on double newline" do
      {frames, rest} = SSE.split_frames("data: a\n\ndata: b\n\ndata: c")
      assert frames == ["data: a", "data: b"]
      assert rest == "data: c"
    end

    test "handles CRLF" do
      {frames, rest} = SSE.split_frames("data: a\r\n\r\ndata: b")
      assert frames == ["data: a"]
      assert rest == "data: b"
    end

    test "returns empty frames for single incomplete chunk" do
      {frames, rest} = SSE.split_frames("data: partial")
      assert frames == []
      assert rest == "data: partial"
    end

    test "handles empty input" do
      {frames, rest} = SSE.split_frames("")
      assert frames == []
      assert rest == ""
    end
  end

  describe "frame_data/1" do
    test "extracts data lines" do
      assert SSE.frame_data("event: test\ndata: hello") == "hello"
    end

    test "ignores comment lines" do
      assert SSE.frame_data(": comment\nevent: x") == nil
    end

    test "joins multiple data lines" do
      assert SSE.frame_data("data: line1\ndata: line2") == "line1\nline2"
    end
  end

  describe "consume_events/2 with real fixtures" do
    test "parses simple reply fixture" do
      data = File.read!(fixture_path("simple_reply/turn_0.sse"))
      state = SSE.initial_state()

      {st, events, done?} = SSE.consume_events(state, data)

      assert done?
      assert st.stop_reason == "end_turn"
      assert st.text =~ "transistor"
      assert st.text =~ "1947"
      assert st.usage["input_tokens"] == 18
      assert st.usage["output_tokens"] == 36
      assert get_in(st.usage, ["cache_creation", "ephemeral_5m_input_tokens"]) == 0

      text_deltas = for {:text_delta, t} <- events, do: t
      assert length(text_deltas) > 0
      assert Enum.join(text_deltas) =~ "Bell Lab"
      assert Enum.any?(events, &match?({:usage, _}, &1))
    end

    test "parses tool use fixture (turn 0)" do
      data = File.read!(fixture_path("tool_use_echo/turn_0.sse"))
      state = SSE.initial_state()

      {st, events, done?} = SSE.consume_events(state, data)

      assert done?
      assert st.stop_reason == "tool_use"

      # Should have tool_use_start and tool_use_stop events
      assert Enum.any?(events, &match?({:tool_use_start, %{"name" => "froth_echo"}}, &1))
      assert {:tool_use_stop, stop} = Enum.find(events, &match?({:tool_use_stop, _}, &1))
      assert stop["name"] == "froth_echo"
      assert stop["input"] == %{"text" => "test message"}

      content = SSE.blocks_to_content(st.blocks)
      tool_block = Enum.find(content, &(&1["type"] == "tool_use"))
      assert tool_block["input"] == %{"text" => "test message"}
    end

    test "parses tool use fixture (turn 1 - after tool result)" do
      data = File.read!(fixture_path("tool_use_echo/turn_1.sse"))
      state = SSE.initial_state()

      {st, events, done?} = SSE.consume_events(state, data)

      assert done?
      assert st.stop_reason == "end_turn"
      assert st.text =~ "test message"

      text_deltas = for {:text_delta, t} <- events, do: t
      assert length(text_deltas) > 0
    end

    test "parses thinking fixture" do
      data = File.read!(fixture_path("thinking_reply/turn_0.sse"))
      state = SSE.initial_state()

      {st, events, done?} = SSE.consume_events(state, data)

      assert done?
      assert st.stop_reason == "end_turn"

      # Thinking events
      assert Enum.any?(events, &match?({:thinking_start, %{"index" => 0}}, &1))
      assert {:thinking_stop, ts} = Enum.find(events, &match?({:thinking_stop, _}, &1))
      assert ts["thinking"] =~ "2"

      # Text events
      text_deltas = for {:text_delta, t} <- events, do: t
      full_text = Enum.join(text_deltas)
      assert full_text =~ "2 + 2"

      # Content blocks should have both thinking and text
      content = SSE.blocks_to_content(st.blocks)
      assert Enum.any?(content, &(&1["type"] == "thinking"))
      assert Enum.any?(content, &(&1["type"] == "text"))
    end
  end

  describe "blocks_to_content/1" do
    test "sorts by index and cleans internal keys" do
      blocks = %{
        1 => %{"type" => "text", "text" => "second"},
        0 => %{"type" => "text", "text" => "first", "__input_json_buf" => "leftover"}
      }

      content = SSE.blocks_to_content(blocks)

      assert content == [
               %{"type" => "text", "text" => "first"},
               %{"type" => "text", "text" => "second"}
             ]
    end
  end

  defp fixture_path(name), do: Path.join([__DIR__, "..", "..", "fixtures", "sse", name])
end
