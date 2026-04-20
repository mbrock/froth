defmodule Froth.Telemetry.Store do
  @moduledoc """
  Persists telemetry events to a Postgres table asynchronously.

  Attaches to all [:froth, **] telemetry events and writes each event
  through a GenServer as soon as it is received.
  """

  use GenServer

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
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:event, event_name, measurements, metadata}, state) do
    persist_entry(%{
      event: Enum.join(event_name, "."),
      span_id: to_string_or_nil(metadata[:span_id]),
      parent_id: to_string_or_nil(metadata[:parent_id]),
      measurements: safe_json(measurements),
      metadata: safe_json(metadata),
      inserted_at: DateTime.utc_now()
    })

    {:noreply, state}
  end

  defp persist_entry(entry) do
    Froth.Repo.insert_all("events", [entry], log: false)
  rescue
    e ->
      require Logger
      Logger.warning("Telemetry store persist failed: #{Exception.message(e)}")
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

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)
end
