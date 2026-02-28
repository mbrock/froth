defmodule Froth.Telemetry.Broadcaster do
  @moduledoc """
  Telemetry handler that re-broadcasts events to Phoenix PubSub.

  Broadcasts to `"anthropic:<request_id>"` for request-level events
  and to the global `"notes"` topic via `Froth.broadcast/2`.
  """

  def attach(events) do
    :telemetry.attach_many(
      "froth-telemetry-broadcaster",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:froth, :anthropic, :request, :start], _measurements, meta, _config) do
    broadcast(meta, {:request_start, %{model: meta[:model], mode: meta[:mode]}})
  end

  def handle_event([:froth, :anthropic, :request, :stop], _measurements, meta, _config) do
    broadcast(meta, {:request_stop, %{ok: meta[:ok], stop_reason: meta[:stop_reason], usage: meta[:usage]}})
  end

  def handle_event([:froth, :anthropic, :request, :exception], _measurements, meta, _config) do
    broadcast(meta, {:request_exception, %{kind: meta[:kind], reason: meta[:reason]}})
  end

  def handle_event([:froth, :http, :sse | _rest] = event, _measurements, meta, _config) do
    sse_type = List.last(event)
    broadcast(meta, {:sse, sse_type, meta})
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp broadcast(%{request_id: request_id}, message) when is_binary(request_id) do
    Froth.broadcast("anthropic:#{request_id}", message)
  end

  defp broadcast(_meta, _message), do: :ok
end
