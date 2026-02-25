defmodule Froth.Anthropic.SSE do
  @moduledoc false

  def split_frames(buf) do
    # Support both LF and CRLF. We normalize CRLF to LF for parsing.
    buf = String.replace(buf, "\r\n", "\n")
    parts = String.split(buf, "\n\n")

    case parts do
      [] ->
        {[], ""}

      [single] ->
        {[], single}

      _ ->
        frames = Enum.slice(parts, 0, length(parts) - 1)
        rest = List.last(parts) || ""
        {frames, rest}
    end
  end

  def frame_data(frame) do
    data_lines =
      frame
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        line = String.trim_leading(line)

        cond do
          line == "" ->
            []

          String.starts_with?(line, ":") ->
            []

          String.starts_with?(line, "data:") ->
            [String.trim_leading(String.replace_prefix(line, "data:", ""))]

          true ->
            []
        end
      end)

    case data_lines do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  def extract_text_delta(%{"delta" => %{"text" => text}}) when is_binary(text), do: text

  def extract_text_delta(%{"type" => "content_block_delta", "delta" => %{"text" => text}})
      when is_binary(text),
      do: text

  def extract_text_delta(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => text}
      })
      when is_binary(text),
      do: text

  def extract_text_delta(_), do: nil

  def initial_state do
    %{
      status: nil,
      buf: "",
      err_buf: "",
      text: "",
      blocks: %{},
      stop_reason: nil,
      usage: %{},
      message_id: nil,
      model: nil
    }
  end

  def blocks_to_content(blocks) when is_map(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, block} ->
      block
      |> Map.delete("__input_json_buf")
      |> Map.delete("__input_json")
    end)
  end

  def consume_events(%{buf: buf} = state, data) when is_binary(data) do
    buf = buf <> data
    {frames, rest} = split_frames(buf)

    {st, events, done?} =
      Enum.reduce(frames, {state, [], false}, fn frame, {st, acc_events, acc_done} ->
        if acc_done do
          {st, acc_events, acc_done}
        else
          case frame_data(frame) do
            nil ->
              {st, acc_events, acc_done}

            "[DONE]" ->
              {st, acc_events, true}

            json ->
              case Jason.decode(json) do
                {:ok, %{"type" => "message_stop"}} ->
                  {st, acc_events, true}

                {:ok, %{"type" => "error"} = payload} ->
                  {st, acc_events ++ [inspect(payload)], true}

                {:ok, payload} ->
                  {st, new_events} = handle_payload(st, payload)
                  {st, acc_events ++ new_events, acc_done}

                {:error, _} ->
                  {st, acc_events, acc_done}
              end
          end
        end
      end)

    {%{st | buf: rest}, events, done?}
  end

  def handle_payload(
        state,
        %{
          "type" => "message_start",
          "message" => message
        }
      )
      when is_map(message) do
    message_start_event =
      if is_binary(message["id"]) and is_binary(message["model"]) do
        [{:message_start, %{"id" => message["id"], "model" => message["model"]}}]
      else
        []
      end

    state =
      state
      |> maybe_put_model(message)
      |> maybe_put_message_id(message)
      |> maybe_merge_usage(Map.get(message, "usage"))

    events =
      message_start_event ++ usage_event("message_start", state.usage, Map.get(message, "usage"))

    {state, events}
  end

  def handle_payload(state, %{"type" => "message_delta"} = payload) do
    delta = Map.get(payload, "delta", %{})
    usage = Map.get(payload, "usage")

    state =
      state
      |> maybe_put_stop_reason(Map.get(delta, "stop_reason"))
      |> maybe_merge_usage(usage)

    events = usage_event("message_delta", state.usage, usage)
    {state, events}
  end

  def handle_payload(
        state,
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "thinking"} = cb
        }
      )
      when is_integer(idx) do
    block =
      cb
      |> Map.put_new("thinking", "")
      |> Map.put("__thinking_buf", "")
      |> Map.put("__signature_buf", "")

    {%{state | blocks: Map.put(state.blocks, idx, block)}, [{:thinking_start, %{"index" => idx}}]}
  end

  def handle_payload(
        state,
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "tool_use", "id" => id, "name" => name} = cb
        }
      )
      when is_integer(idx) and is_binary(id) and is_binary(name) do
    block =
      cb
      |> Map.put_new("input", %{})
      |> Map.put("__input_json_buf", "")

    events = [{:tool_use_start, %{"id" => id, "name" => name, "input" => Map.get(cb, "input")}}]
    {%{state | blocks: Map.put(state.blocks, idx, block)}, events}
  end

  def handle_payload(
        state,
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "text"}
        }
      )
      when is_integer(idx) do
    block = %{"type" => "text", "text" => ""}
    {%{state | blocks: Map.put(state.blocks, idx, block)}, []}
  end

  def handle_payload(state, %{"type" => "content_block_delta", "index" => idx} = payload)
      when is_integer(idx) do
    delta = Map.get(payload, "delta", %{})
    block = Map.get(state.blocks, idx, %{})
    text_delta = extract_text_delta(payload)

    cond do
      is_binary(text_delta) and text_delta != "" ->
        block = Map.update(block, "text", text_delta, &(&1 <> text_delta))

        state = %{
          state
          | text: state.text <> text_delta,
            blocks: Map.put(state.blocks, idx, block)
        }

        {state, [{:text_delta, text_delta}]}

      match?(%{"type" => "thinking_delta", "thinking" => _}, delta) ->
        %{"thinking" => t} = delta
        block = Map.update(block, "__thinking_buf", t, &(&1 <> t))
        state = %{state | blocks: Map.put(state.blocks, idx, block)}
        {state, [{:thinking_delta, %{"index" => idx, "delta" => t}}]}

      match?(%{"type" => "signature_delta", "signature" => _}, delta) ->
        %{"signature" => s} = delta
        block = Map.update(block, "__signature_buf", s, &(&1 <> s))
        state = %{state | blocks: Map.put(state.blocks, idx, block)}
        {state, []}

      match?(%{"type" => "input_json_delta", "partial_json" => _}, delta) ->
        %{"partial_json" => pj} = delta
        id = Map.get(block, "id")
        block = Map.update(block, "__input_json_buf", pj, &(&1 <> pj))
        state = %{state | blocks: Map.put(state.blocks, idx, block)}

        events =
          if is_binary(id) do
            [{:tool_use_delta, %{"id" => id, "partial_json" => pj}}]
          else
            []
          end

        {state, events}

      true ->
        {state, []}
    end
  end

  def handle_payload(state, %{"type" => "content_block_stop", "index" => idx})
      when is_integer(idx) do
    case Map.get(state.blocks, idx) do
      %{"type" => "thinking"} = b ->
        finalize_thinking_block(state, idx, b)

      %{"type" => "tool_use", "id" => id, "name" => name} = b
      when is_binary(id) and is_binary(name) ->
        finalize_tool_use_block(state, idx, b)

      _ ->
        {state, []}
    end
  end

  def handle_payload(state, _payload), do: {state, []}

  defp finalize_thinking_block(state, idx, block) do
    thinking = Map.get(block, "__thinking_buf", "")
    signature = Map.get(block, "__signature_buf", "")

    block =
      block
      |> Map.put("thinking", thinking)
      |> Map.put("signature", signature)
      |> Map.delete("__thinking_buf")
      |> Map.delete("__signature_buf")

    state = %{state | blocks: Map.put(state.blocks, idx, block)}

    {state,
     [{:thinking_stop, %{"index" => idx, "thinking" => thinking, "signature" => signature}}]}
  end

  defp finalize_tool_use_block(state, idx, block) do
    %{"id" => id, "name" => name} = block

    {input, block} =
      case block do
        %{"input" => %{} = input} when map_size(input) > 0 ->
          {input, block}

        %{"__input_json_buf" => buf} when is_binary(buf) and buf != "" ->
          case Jason.decode(buf) do
            {:ok, %{} = input} -> {input, Map.put(block, "input", input)}
            _ -> {%{}, block}
          end

        _ ->
          {%{}, block}
      end

    block = Map.delete(block, "__input_json_buf")
    state = %{state | blocks: Map.put(state.blocks, idx, block)}
    {state, [{:tool_use_stop, %{"id" => id, "name" => name, "input" => input}}]}
  end

  defp maybe_put_stop_reason(state, stop_reason) when is_binary(stop_reason) do
    %{state | stop_reason: stop_reason}
  end

  defp maybe_put_stop_reason(state, _stop_reason), do: state

  defp maybe_merge_usage(state, usage) when is_map(usage) do
    %{state | usage: merge_usage(state.usage, usage)}
  end

  defp maybe_merge_usage(state, _usage), do: state

  defp maybe_put_message_id(state, %{"id" => id}) when is_binary(id) do
    %{state | message_id: id}
  end

  defp maybe_put_message_id(state, _message), do: state

  defp maybe_put_model(state, %{"model" => model}) when is_binary(model) do
    %{state | model: model}
  end

  defp maybe_put_model(state, _message), do: state

  defp usage_event(_phase, _accumulated, usage) when not is_map(usage), do: []

  defp usage_event(phase, accumulated, usage) do
    [{:usage, %{"phase" => phase, "usage" => usage, "accumulated_usage" => accumulated}}]
  end

  defp merge_usage(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        merge_usage(left_val, right_val)
      else
        right_val
      end
    end)
  end
end
