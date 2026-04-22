defmodule Froth.Telemetry.Logger do
  @moduledoc """
  Subscribes to the `"events"` pub/sub topic and writes a structured
  Logger line per event. Level is derived from the event name; the
  event row's measurements and metadata become Logger metadata.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = Phoenix.PubSub.subscribe(Froth.PubSub, "events")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, %Froth.Event{} = event}, state) do
    log(event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp log(%Froth.Event{
         event: name,
         measurements: measurements,
         metadata: metadata
       }) do
    level = level_for(name)

    report =
      [{:event, name}] ++
        normalize_measurements(measurements) ++
        Enum.to_list(metadata || %{})

    Logger.log(level, report)
  end

  defp level_for("froth." <> _ = name) do
    cond do
      String.ends_with?(name, ".exception") -> :error
      String.starts_with?(name, "froth.http.sse") -> :debug
      String.ends_with?(name, ".start") -> :debug
      true -> :info
    end
  end

  defp level_for(_), do: :info

  defp normalize_measurements(m) when is_map(m) and map_size(m) == 0, do: []

  defp normalize_measurements(m) when is_map(m) do
    converted =
      Map.new(m, fn
        {"duration", native} when is_integer(native) ->
          {"duration_ms",
           System.convert_time_unit(native, :native, :millisecond)}

        {k, v} ->
          {k, v}
      end)

    [{:measurements, converted}]
  end

  defp normalize_measurements(_), do: []
end
