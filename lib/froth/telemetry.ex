defmodule Froth.Telemetry do
  @moduledoc """
  Central telemetry event registry.

  Defines all [:froth, **] event names and attaches both the Logger
  and Store handlers on application startup.
  """

  @froth_events [
    [:froth, :anthropic, :request],
    [:froth, :anthropic, :stream, :start],
    [:froth, :anthropic, :stream, :stop],
    [:froth, :anthropic, :stream, :error],
    [:froth, :anthropic, :turn, :start],
    [:froth, :anthropic, :turn, :stop],
    [:froth, :anthropic, :tool, :start],
    [:froth, :anthropic, :tool, :stop],
    [:froth, :anthropic, :tool_loop, :stop],
    [:froth, :anthropic, :sse, :message_start],
    [:froth, :anthropic, :sse, :thinking_start],
    [:froth, :anthropic, :sse, :thinking_stop],
    [:froth, :anthropic, :sse, :tool_use_start],
    [:froth, :anthropic, :sse, :tool_use_stop],
    [:froth, :anthropic, :sse, :tool_result],
    [:froth, :anthropic, :sse, :usage],
    [:froth, :anthropic, :sse, :http_status]
  ]

  def events, do: @froth_events

  def attach_handlers do
    Froth.Telemetry.Logger.attach(@froth_events)
    Froth.Telemetry.Store.attach(@froth_events)
  end
end
