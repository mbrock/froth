defmodule Froth.Telemetry.Store do
  @moduledoc """
  Persists telemetry events to a Postgres table asynchronously.

  Attaches to all [:froth, **] telemetry events and batches inserts
  through a GenServer to avoid blocking the caller's process.
  """

  use GenServer

  @flush_interval_ms 1_000
  @max_batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def attach(events) do
    :telemetry.attach_many(
      "froth-telemetry-store",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event_name, measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:event, event_name, measurements, metadata})
  end

  @impl true
  def init(_opts) do
    schedule_flush()
    {:ok, %{buffer: []}}
  end

  @impl true
  def handle_cast({:event, event_name, measurements, metadata}, state) do
    entry = %{
      event: Enum.join(event_name, "."),
      measurements: safe_json(measurements),
      metadata: safe_json(metadata),
      inserted_at: DateTime.utc_now()
    }

    buffer = [entry | state.buffer]

    if length(buffer) >= @max_batch_size do
      flush(buffer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    if state.buffer != [], do: flush(state.buffer)
    schedule_flush()
    {:noreply, %{state | buffer: []}}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp flush(entries) do
    Froth.Repo.insert_all("telemetry_events", entries, log: false)
  rescue
    e ->
      require Logger
      Logger.warning("Telemetry store flush failed: #{Exception.message(e)}")
  end

  defp safe_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp safe_json(other), do: %{"value" => safe_value(other)}

  defp safe_value(v) when is_binary(v), do: v
  defp safe_value(v) when is_number(v), do: v
  defp safe_value(v) when is_boolean(v), do: v
  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)
  defp safe_value(%{} = v), do: safe_json(v)
  defp safe_value(v), do: inspect(v)
end
