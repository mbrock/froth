defmodule Froth.Codex.Events do
  @moduledoc """
  Persistence helpers for Codex session timeline entries.
  """

  import Ecto.Query

  alias Froth.Codex.Event
  alias Froth.Telemetry.Span
  alias Froth.Repo

  @max_stored_entries 2_000

  @spec load_recent_entries(String.t(), pos_integer()) :: {list(map()), non_neg_integer()}
  def load_recent_entries(session_id, limit \\ 800) when is_binary(session_id) and limit > 0 do
    events =
      from(e in Event,
        where: e.session_id == ^session_id,
        order_by: [desc: e.sequence],
        limit: ^limit
      )
      |> Repo.all(log: false)
      |> Enum.reverse()

    entries =
      Enum.map(events, fn event ->
        event_to_entry(event)
      end)

    max_sequence =
      case List.last(events) do
        nil -> 0
        event -> event.sequence || 0
      end

    {entries, max_sequence}
  rescue
    error ->
      Span.execute([:froth, :codex, :events_load_failed], nil, %{
        session_id: session_id,
        error: Exception.message(error)
      })

      {[], 0}
  end

  @spec list_sessions(pos_integer()) :: [map()]
  def list_sessions(limit \\ 80) when is_integer(limit) and limit > 0 do
    latest_by_session =
      from(e in Event,
        group_by: e.session_id,
        select: %{
          session_id: e.session_id,
          max_sequence: max(e.sequence),
          last_seen_at: max(e.inserted_at)
        }
      )

    from(e in Event,
      join: latest in subquery(latest_by_session),
      on: e.session_id == latest.session_id and e.sequence == latest.max_sequence,
      order_by: [desc: latest.last_seen_at],
      limit: ^limit,
      select: %{
        session_id: e.session_id,
        last_sequence: e.sequence,
        last_kind: e.kind,
        last_body: e.body,
        last_seen_at: latest.last_seen_at
      }
    )
    |> Repo.all(log: false)
  rescue
    error ->
      Span.execute([:froth, :codex, :events_list_failed], nil, %{error: Exception.message(error)})
      []
  end

  @spec upsert_entry(String.t(), map()) :: :ok
  def upsert_entry(session_id, entry) when is_binary(session_id) and is_map(entry) do
    id = to_string(entry[:id] || entry["id"])
    sequence = entry[:sequence] || entry["sequence"] || 0
    kind = entry[:kind] || entry["kind"] || :event
    body = entry[:body] || entry["body"] || ""

    metadata =
      entry
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.drop(["id", "kind", "body", "sequence"])

    attrs = %{
      session_id: session_id,
      entry_id: id,
      sequence: sequence,
      kind: to_string(kind),
      body: to_string(body),
      metadata: metadata
    }

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          sequence: attrs.sequence,
          kind: attrs.kind,
          body: attrs.body,
          metadata: attrs.metadata
        ]
      ],
      conflict_target: [:session_id, :entry_id],
      log: false
    )

    maybe_prune(session_id, sequence)
    :ok
  rescue
    error ->
      Span.execute([:froth, :codex, :events_upsert_failed], nil, %{
        session_id: session_id,
        entry_id: inspect(entry[:id] || entry["id"]),
        error: Exception.message(error)
      })

      :ok
  end

  defp maybe_prune(session_id, sequence)
       when is_binary(session_id) and is_integer(sequence) and sequence > 0 and
              rem(sequence, 100) == 0 do
    cutoff = max(sequence - @max_stored_entries, 0)

    from(e in Event, where: e.session_id == ^session_id and e.sequence < ^cutoff)
    |> Repo.delete_all(log: false)

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_prune(_session_id, _sequence), do: :ok

  defp event_to_entry(event) do
    metadata = event.metadata || %{}

    entry = %{
      id: event.entry_id,
      kind: to_kind(event.kind),
      body: event.body || "",
      sequence: event.sequence || 0
    }

    entry
    |> maybe_put(metadata, "status")
    |> maybe_put(metadata, "output")
    |> maybe_put(metadata, "label")
  end

  defp maybe_put(entry, metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) and value != "" -> Map.put(entry, String.to_atom(key), value)
      _ -> entry
    end
  end

  defp to_kind(kind) when is_binary(kind) do
    case kind do
      "assistant" -> :assistant
      "error" -> :error
      "event" -> :event
      "reasoning" -> :reasoning
      "status" -> :status
      "system" -> :system
      "tool" -> :tool
      "user" -> :user
      _ -> :event
    end
  end

  defp to_kind(_), do: :event
end
