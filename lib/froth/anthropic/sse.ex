defmodule Froth.Anthropic.SSE do
  @moduledoc false

  alias Froth.LLM.Providers.Anthropic, as: AnthropicProvider
  alias Froth.LLM.Store

  def split_frames(buf) do
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

  def extract_text_delta(payload), do: AnthropicProvider.extract_text_delta(payload)

  def initial_state do
    sync_compat_fields(%{
      status: nil,
      buf: "",
      err_buf: "",
      store: Store.new(),
      done?: false
    })
  end

  def blocks_to_content(blocks) when is_map(blocks),
    do: AnthropicProvider.blocks_to_content(blocks)

  def consume_events(%{buf: buf} = state, data) when is_binary(data) do
    buf = buf <> data
    {frames, rest} = split_frames(buf)

    {state, events, done?} =
      Enum.reduce(frames, {state, [], false}, fn frame, {current, acc_events, acc_done} ->
        if acc_done do
          {current, acc_events, acc_done}
        else
          case frame_data(frame) do
            nil ->
              {current, acc_events, acc_done}

            "[DONE]" ->
              {current, acc_events, true}

            json ->
              case Jason.decode(json) do
                {:ok, %{} = payload} ->
                  {next, payload_events, payload_done?} = consume_payload(current, payload)
                  {next, acc_events ++ payload_events, acc_done || payload_done?}

                {:error, _} ->
                  {current, acc_events, acc_done}
              end
          end
        end
      end)

    state = sync_compat_fields(%{state | buf: rest, done?: done?})
    {state, events, done?}
  end

  def consume_payload(state, payload) when is_map(payload) do
    {edits, done?} = AnthropicProvider.decode_payload(payload, state.store)
    store = Store.apply_edits(state.store, edits)
    next = sync_compat_fields(%{state | store: store, done?: done? || state.done?})
    events = Enum.map(edits, &AnthropicProvider.project_event/1) |> Enum.reject(&is_nil/1)
    {next, events, done?}
  end

  def result(%{store: store}) do
    AnthropicProvider.finalize(store)
  end

  defp sync_compat_fields(state) do
    result = AnthropicProvider.finalize(state.store)
    message = Store.get(state.store, ["message"], %{})
    blocks = Map.get(message, "blocks", %{})

    Map.merge(state, %{
      text: result.text,
      blocks: blocks,
      stop_reason: result.stop_reason,
      usage: result.usage,
      model: result.model,
      message_id: result.message_id
    })
  end
end
