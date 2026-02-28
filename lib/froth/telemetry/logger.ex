defmodule Froth.Telemetry.Logger do
  @moduledoc """
  Formats telemetry events into structured Logger calls.

  Attaches to [:froth, **] events and produces concise, meaningful log
  lines with structured metadata for journald / stdout consumption.
  """

  require Logger

  def attach(events) do
    :telemetry.attach_many(
      "froth-telemetry-logger",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  # -- Anthropic request span --

  def handle_event([:froth, :anthropic, :request, :start], _measurements, meta, _config) do
    Logger.info("anthropic request start #{meta[:mode]} #{meta[:model]}",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      mode: meta[:mode],
      model: meta[:model],
      messages: meta[:message_count],
      tools: meta[:tool_count]
    )
  end

  def handle_event([:froth, :anthropic, :request, :stop], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.info("anthropic request stop #{meta[:mode]} #{ms}ms ok=#{meta[:ok]}",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      mode: meta[:mode],
      duration_ms: ms,
      ok: meta[:ok],
      stop_reason: meta[:stop_reason],
      text_len: meta[:text_len],
      usage: meta[:usage]
    )
  end

  def handle_event([:froth, :anthropic, :request, :exception], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.error("anthropic request exception #{meta[:mode]} #{ms}ms",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      kind: meta[:kind],
      reason: inspect(meta[:reason]),
      duration_ms: ms
    )
  end

  # -- Anthropic turn span --

  def handle_event([:froth, :anthropic, :turn, :start], _measurements, meta, _config) do
    Logger.info("anthropic turn #{meta[:turn]} start",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      turn: meta[:turn],
      messages: meta[:message_count],
      tools: meta[:tool_count]
    )
  end

  def handle_event([:froth, :anthropic, :turn, :stop], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.info("anthropic turn #{meta[:turn]} #{meta[:stop_reason]} #{ms}ms",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      turn: meta[:turn],
      stop_reason: meta[:stop_reason],
      text_len: meta[:text_len],
      tool_use_count: meta[:tool_use_count],
      duration_ms: ms,
      usage: meta[:usage]
    )
  end

  def handle_event([:froth, :anthropic, :turn, :exception], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.error("anthropic turn #{meta[:turn]} exception #{ms}ms",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      turn: meta[:turn],
      kind: meta[:kind],
      reason: inspect(meta[:reason]),
      duration_ms: ms
    )
  end

  # -- Tool execution span --

  def handle_event([:froth, :anthropic, :tool_exec, :start], _measurements, meta, _config) do
    Logger.info("tool exec #{meta[:tool_name]}",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      turn: meta[:turn],
      tool_use_id: meta[:tool_use_id],
      tool_name: meta[:tool_name]
    )
  end

  def handle_event([:froth, :anthropic, :tool_exec, :stop], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])
    level = if meta[:is_error], do: :warning, else: :info

    Logger.log(level, "tool done #{meta[:tool_name]}#{if meta[:is_error], do: " ERROR"} #{ms}ms",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      turn: meta[:turn],
      tool_use_id: meta[:tool_use_id],
      tool_name: meta[:tool_name],
      is_error: meta[:is_error],
      duration_ms: ms
    )
  end

  def handle_event([:froth, :anthropic, :tool_exec, :exception], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.error("tool exception #{meta[:tool_name]} #{ms}ms",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      turn: meta[:turn],
      tool_use_id: meta[:tool_use_id],
      tool_name: meta[:tool_name],
      kind: meta[:kind],
      reason: inspect(meta[:reason]),
      duration_ms: ms
    )
  end

  # -- SSE-level events (debug) --

  def handle_event([:froth, :anthropic, :sse, type], _m, meta, _config) do
    Logger.debug("sse #{type}",
      request_id: meta[:request_id],
      cycle_id: meta[:cycle_id],
      sse_type: type,
      data: meta[:data]
    )
  end

  # -- Agent lifecycle --

  def handle_event([:froth, :agent, :cycle, :start], _measurements, meta, _config) do
    Logger.info("agent cycle start",
      cycle_id: meta[:cycle_id],
      model: meta[:model]
    )
  end

  def handle_event([:froth, :agent, :cycle, :stop], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.info("agent cycle stop #{meta[:reason]} #{ms}ms",
      cycle_id: meta[:cycle_id],
      reason: inspect(meta[:reason]),
      phase: inspect(meta[:phase]),
      duration_ms: ms
    )
  end

  def handle_event([:froth, :agent, :think, :start], _measurements, meta, _config) do
    Logger.debug("agent think start",
      cycle_id: meta[:cycle_id]
    )
  end

  def handle_event([:froth, :agent, :think, :stop], measurements, meta, _config) do
    ms = to_ms(measurements[:duration])

    Logger.debug("agent think stop #{ms}ms",
      cycle_id: meta[:cycle_id],
      duration_ms: ms,
      error: meta[:error] && inspect(meta[:error])
    )
  end

  def handle_event([:froth, :agent, :empty_retry], measurements, meta, _config) do
    Logger.warning("agent empty response retry #{measurements[:retry]}",
      cycle_id: meta[:cycle_id],
      retry: measurements[:retry]
    )
  end

  # -- Catch-all --

  def handle_event(event_name, measurements, metadata, _config) do
    Logger.debug(Enum.join(event_name, "."),
      measurements: inspect(measurements),
      metadata: inspect(metadata)
    )
  end

  defp to_ms(nil), do: nil
  defp to_ms(native) when is_integer(native), do: System.convert_time_unit(native, :native, :millisecond)
  defp to_ms(_), do: nil
end
