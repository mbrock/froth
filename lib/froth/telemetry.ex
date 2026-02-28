defmodule Froth.Telemetry do
  @moduledoc """
  Central telemetry event registry.

  Defines all [:froth, **] event names and attaches the Logger,
  Store, and Broadcaster handlers on application startup.
  """

  @anthropic_span_events [
    [:froth, :anthropic, :request, :start],
    [:froth, :anthropic, :request, :stop],
    [:froth, :anthropic, :request, :exception],
    [:froth, :anthropic, :turn, :start],
    [:froth, :anthropic, :turn, :stop],
    [:froth, :anthropic, :turn, :exception],
    [:froth, :anthropic, :tool_exec, :start],
    [:froth, :anthropic, :tool_exec, :stop],
    [:froth, :anthropic, :tool_exec, :exception]
  ]

  @anthropic_sse_events [
    [:froth, :anthropic, :sse, :http_status],
    [:froth, :anthropic, :sse, :message_start],
    [:froth, :anthropic, :sse, :thinking_start],
    [:froth, :anthropic, :sse, :thinking_stop],
    [:froth, :anthropic, :sse, :tool_use_start],
    [:froth, :anthropic, :sse, :tool_use_stop],
    [:froth, :anthropic, :sse, :tool_result],
    [:froth, :anthropic, :sse, :usage],
    [:froth, :anthropic, :sse, :message_stop]
  ]

  @agent_events [
    [:froth, :agent, :cycle, :start],
    [:froth, :agent, :cycle, :stop],
    [:froth, :agent, :think, :start],
    [:froth, :agent, :think, :stop],
    [:froth, :agent, :empty_retry]
  ]

  @all_events @anthropic_span_events ++ @anthropic_sse_events ++ @agent_events

  def events, do: @all_events

  def attach_handlers do
    Froth.Telemetry.Logger.attach(@all_events)
    Froth.Telemetry.Store.attach(@all_events)
    Froth.Telemetry.Broadcaster.attach(@anthropic_span_events ++ @anthropic_sse_events)
  end
end
