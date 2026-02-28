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

  # -- Anthropic streaming lifecycle --

  def handle_event(
        [:froth, :anthropic, :stream, :start],
        measurements,
        metadata,
        _config
      ) do
    Logger.info("anthropic stream start",
      request_id: metadata[:request_id],
      mode: metadata[:mode],
      model: metadata[:model],
      messages: measurements[:message_count],
      tools: measurements[:tool_count]
    )
  end

  def handle_event(
        [:froth, :anthropic, :stream, :stop],
        measurements,
        metadata,
        _config
      ) do
    duration_ms = to_ms(measurements[:duration])

    Logger.info("anthropic stream stop #{metadata[:stop_reason]} #{duration_ms}ms",
      request_id: metadata[:request_id],
      mode: metadata[:mode],
      stop_reason: metadata[:stop_reason],
      duration_ms: duration_ms,
      text_len: measurements[:text_len],
      content_blocks: measurements[:content_blocks]
    )
  end

  def handle_event(
        [:froth, :anthropic, :stream, :error],
        _measurements,
        metadata,
        _config
      ) do
    Logger.error("anthropic stream error",
      request_id: metadata[:request_id],
      mode: metadata[:mode],
      reason: inspect(metadata[:reason])
    )
  end

  # -- Anthropic tool loop turns --

  def handle_event(
        [:froth, :anthropic, :turn, :start],
        measurements,
        metadata,
        _config
      ) do
    Logger.info("anthropic turn #{metadata[:turn]} start",
      request_id: metadata[:request_id],
      turn: metadata[:turn],
      messages: measurements[:message_count],
      tools: measurements[:tool_count]
    )
  end

  def handle_event(
        [:froth, :anthropic, :turn, :stop],
        measurements,
        metadata,
        _config
      ) do
    Logger.info("anthropic turn #{metadata[:turn]} #{metadata[:stop_reason]}",
      request_id: metadata[:request_id],
      turn: metadata[:turn],
      stop_reason: metadata[:stop_reason],
      text_len: measurements[:text_len],
      tool_use_count: measurements[:tool_use_count],
      usage: measurements[:usage]
    )
  end

  # -- Tool execution --

  def handle_event(
        [:froth, :anthropic, :tool, :start],
        _measurements,
        metadata,
        _config
      ) do
    Logger.info("tool exec #{metadata[:tool_name]}",
      request_id: metadata[:request_id],
      turn: metadata[:turn],
      tool_use_id: metadata[:tool_use_id],
      tool_name: metadata[:tool_name]
    )
  end

  def handle_event(
        [:froth, :anthropic, :tool, :stop],
        _measurements,
        metadata,
        _config
      ) do
    level = if metadata[:is_error], do: :warning, else: :info

    Logger.log(level, "tool done #{metadata[:tool_name]}#{if metadata[:is_error], do: " ERROR"}",
      request_id: metadata[:request_id],
      turn: metadata[:turn],
      tool_use_id: metadata[:tool_use_id],
      tool_name: metadata[:tool_name],
      is_error: metadata[:is_error]
    )
  end

  # -- Tool loop completion --

  def handle_event(
        [:froth, :anthropic, :tool_loop, :stop],
        measurements,
        metadata,
        _config
      ) do
    Logger.info("anthropic tool loop complete",
      request_id: metadata[:request_id],
      text_len: measurements[:text_len],
      api_messages: measurements[:api_message_count],
      usage: measurements[:usage]
    )
  end

  # -- SSE-level streaming events (debug level) --

  def handle_event([:froth, :anthropic, :sse, :message_start], _m, metadata, _config) do
    Logger.debug("sse message_start",
      request_id: metadata[:request_id],
      response_id: metadata[:response_id],
      model: metadata[:model]
    )
  end

  def handle_event([:froth, :anthropic, :sse, :thinking_start], _m, metadata, _config) do
    Logger.debug("sse thinking_start",
      request_id: metadata[:request_id],
      index: metadata[:index]
    )
  end

  def handle_event([:froth, :anthropic, :sse, :thinking_stop], _m, metadata, _config) do
    Logger.debug("sse thinking_stop",
      request_id: metadata[:request_id],
      thinking_len: metadata[:thinking_len]
    )
  end

  def handle_event([:froth, :anthropic, :sse, :tool_use_start], _m, metadata, _config) do
    Logger.debug("sse tool_use_start #{metadata[:tool_name]}",
      request_id: metadata[:request_id],
      tool_use_id: metadata[:tool_use_id],
      tool_name: metadata[:tool_name]
    )
  end

  def handle_event([:froth, :anthropic, :sse, :tool_use_stop], _m, metadata, _config) do
    Logger.debug("sse tool_use_stop #{metadata[:tool_name]}",
      request_id: metadata[:request_id],
      tool_use_id: metadata[:tool_use_id],
      tool_name: metadata[:tool_name]
    )
  end

  def handle_event([:froth, :anthropic, :sse, :usage], _m, metadata, _config) do
    Logger.debug("sse usage #{metadata[:phase]}",
      request_id: metadata[:request_id],
      phase: metadata[:phase],
      usage: metadata[:usage]
    )
  end

  def handle_event([:froth, :anthropic, :sse, :http_status], _m, metadata, _config) do
    Logger.debug("sse http #{metadata[:status]}",
      request_id: metadata[:request_id],
      status: metadata[:status]
    )
  end

  # -- Request-level telemetry (existing) --

  def handle_event([:froth, :anthropic, :request], measurements, metadata, _config) do
    duration_ms = to_ms(measurements[:duration])

    Logger.info("anthropic request #{metadata[:model]} #{duration_ms}ms ok=#{metadata[:ok?]}",
      model: metadata[:model],
      duration_ms: duration_ms,
      ok: metadata[:ok?],
      status: metadata[:status],
      stream: metadata[:stream]
    )
  end

  # -- Catch-all for any froth events we haven't formatted yet --

  def handle_event(event_name, measurements, metadata, _config) do
    Logger.debug(Enum.join(event_name, "."),
      measurements: inspect(measurements),
      metadata: inspect(metadata)
    )
  end

  defp to_ms(nil), do: nil
  defp to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
