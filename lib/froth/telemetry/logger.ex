defmodule Froth.Telemetry.Logger do
  @moduledoc """
  Generic telemetry-to-Logger bridge.

  Emits every telemetry event as a structured Logger call. The event
  name becomes the message, measurements and metadata become Logger
  metadata fields. Presentation is deferred to the Logger formatter.
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

  def handle_event(event_name, measurements, metadata, _config) do
    level = level_for(event_name)
    measurements = normalize_measurements(measurements)

    report =
      [{:event, Enum.join(event_name, ".")}] ++
        if(measurements, do: [{:measurements, measurements}], else: []) ++
        Enum.to_list(metadata)

    Logger.log(level, report)
  end

  defp level_for([:froth, _, _, :exception]), do: :error
  defp level_for([:froth, :http, :sse | _]), do: :debug
  defp level_for([:froth, _, _, :start]), do: :debug
  defp level_for(_), do: :info

  defp normalize_measurements(m) when map_size(m) == 0, do: nil

  defp normalize_measurements(m) do
    Map.new(m, fn
      {:duration, native} when is_integer(native) ->
        {:duration_ms, System.convert_time_unit(native, :native, :millisecond)}

      {:system_time, native} when is_integer(native) ->
        {:system_time, native}

      pair ->
        pair
    end)
  end
end
