defmodule Froth.Follow.Entry do
  @moduledoc """
  A straightforward view of one row from the `events` table.

  Everything the UI renders comes directly from the event itself:
  the name, the ids, the two JSONB bags. A handful of trivial
  projections (family, kind, duration, level) are computed here and
  nowhere else.
  """

  @type mode :: :smart | :raw | :errors

  @type t :: %__MODULE__{
          id: String.t(),
          at: DateTime.t() | NaiveDateTime.t() | nil,
          event: String.t(),
          span_id: String.t() | nil,
          parent_id: String.t() | nil,
          measurements: map(),
          metadata: map(),
          cycle_id: String.t() | nil,
          tool_use_id: String.t() | nil,
          message_id: String.t() | nil,
          family: String.t(),
          kind: String.t(),
          level: :debug | :info | :warn | :error,
          duration_ms: integer() | nil
        }

  defstruct [
    :id,
    :at,
    :event,
    :span_id,
    :parent_id,
    :cycle_id,
    :tool_use_id,
    :message_id,
    :family,
    :kind,
    :level,
    :duration_ms,
    measurements: %{},
    metadata: %{}
  ]

  @spec from_event(Froth.Event.t()) :: t()
  def from_event(%Froth.Event{} = event) do
    measurements = event.measurements || %{}
    metadata = event.metadata || %{}
    {family, kind} = split_name(event.event)

    %__MODULE__{
      id: to_string(event.id),
      at: event.inserted_at,
      event: event.event,
      span_id: event.span_id,
      parent_id: event.parent_id,
      measurements: measurements,
      metadata: metadata,
      cycle_id: metadata["cycle_id"],
      tool_use_id: metadata["tool_use_id"],
      message_id: metadata["message_id"],
      family: family,
      kind: kind,
      level: level_for(event.event, metadata),
      duration_ms: duration_ms(measurements)
    }
  end

  @spec from_row(map()) :: t()
  def from_row(%{} = row) do
    from_event(%Froth.Event{
      id: row[:id] || row["id"],
      event: row[:event] || row["event"] || "froth.unknown",
      span_id: row[:span_id] || row["span_id"],
      parent_id: row[:parent_id] || row["parent_id"],
      measurements: row[:measurements] || row["measurements"] || %{},
      metadata: row[:metadata] || row["metadata"] || %{},
      inserted_at: row[:inserted_at] || row["inserted_at"]
    })
  end

  def visible?(%__MODULE__{}, :raw), do: true
  def visible?(%__MODULE__{level: level}, :errors), do: level == :error
  def visible?(%__MODULE__{level: :debug}, :smart), do: false
  def visible?(%__MODULE__{}, :smart), do: true

  defp split_name(name) when is_binary(name) do
    case String.split(name, ".", parts: 3) do
      ["froth", family, rest] -> {family, rest}
      ["froth", family] -> {family, ""}
      [family | rest] -> {family, Enum.join(rest, ".")}
      _ -> {"event", name}
    end
  end

  defp split_name(_), do: {"event", ""}

  defp level_for(name, metadata) when is_binary(name) do
    cond do
      metadata["level"] == "error" -> :error
      metadata["level"] == "warn" -> :warn
      metadata["level"] == "debug" -> :debug
      String.ends_with?(name, ".exception") -> :error
      String.ends_with?(name, ".failed") -> :error
      String.ends_with?(name, ".error") -> :error
      String.ends_with?(name, ".start") -> :debug
      String.starts_with?(name, "froth.http.sse") -> :debug
      name == "froth.llm.edit" -> :debug
      name == "froth.telegram.cnode.unexpected" -> :debug
      name == "froth.telegram.cnode.output" -> :debug
      name == "froth.telegram.cnode.node_up" -> :debug
      name == "froth.telegram.cnode.node_down" -> :debug
      true -> :info
    end
  end

  defp level_for(_, _), do: :info

  defp duration_ms(measurements) do
    case measurements["duration"] || measurements[:duration] do
      n when is_integer(n) ->
        System.convert_time_unit(n, :native, :millisecond)

      _ ->
        case measurements["duration_ms"] || measurements[:duration_ms] do
          n when is_integer(n) -> n
          _ -> nil
        end
    end
  end
end
