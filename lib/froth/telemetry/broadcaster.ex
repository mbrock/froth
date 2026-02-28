defmodule Froth.Telemetry.Broadcaster do
  @moduledoc """
  Telemetry handler that re-broadcasts events to Phoenix PubSub.
  """

  def attach(events) do
    :telemetry.attach_many(
      "froth-telemetry-broadcaster",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event_name, _measurements, meta, _config) do
    if span_id = meta[:span_id] || meta[:parent_id] do
      type = List.last(event_name)
      Froth.broadcast("telemetry:#{span_id}", {event_name, type, meta})
    end
  end
end
