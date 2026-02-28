defmodule Froth.Telemetry do
  @moduledoc """
  Central telemetry event registry.

  Defines all [:froth, **] event names and attaches the Logger,
  Store, and Broadcaster handlers on application startup.
  """

  @http_events [
    [:froth, :http, :request, :start],
    [:froth, :http, :request, :stop],
    [:froth, :http, :request, :exception],
    [:froth, :http, :sse, :http_status],
    [:froth, :http, :sse, :message_start],
    [:froth, :http, :sse, :message_stop],
    [:froth, :http, :sse, :thinking_start],
    [:froth, :http, :sse, :thinking_stop],
    [:froth, :http, :sse, :tool_use_start],
    [:froth, :http, :sse, :tool_use_stop],
    [:froth, :http, :sse, :tool_result],
    [:froth, :http, :sse, :usage]
  ]

  @anthropic_events [
    [:froth, :anthropic, :request, :start],
    [:froth, :anthropic, :request, :stop],
    [:froth, :anthropic, :request, :exception]
  ]

  @agent_events [
    [:froth, :agent, :cycle, :start],
    [:froth, :agent, :cycle, :stop],
    [:froth, :agent, :think, :start],
    [:froth, :agent, :think, :stop],
    [:froth, :agent, :empty_retry]
  ]

  @all_events @http_events ++ @anthropic_events ++ @agent_events

  def events, do: @all_events

  def attach_handlers do
    Froth.Telemetry.Logger.attach(@all_events)
    Froth.Telemetry.Store.attach(@all_events)
    Froth.Telemetry.Broadcaster.attach(@anthropic_events ++ @http_events)
  end
end
