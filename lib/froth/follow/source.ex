defmodule Froth.Follow.Source do
  @moduledoc false

  import Ecto.Query

  alias Froth.Follow.{Filter, Projector}

  @spec recent_entries(keyword()) :: [Froth.Follow.Entry.t()]
  def recent_entries(opts \\ []) do
    filter = Keyword.get(opts, :filter, Filter.new())
    text = normalize_text(Keyword.get(opts, :text))
    limit = Keyword.get(opts, :limit, 3000)

    query =
      from(e in "events",
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        select: %{
          id: type(e.id, Ecto.UUID),
          event: e.event,
          span_id: e.span_id,
          parent_id: e.parent_id,
          measurements: e.measurements,
          metadata: e.metadata,
          inserted_at: e.inserted_at
        }
      )

    query =
      case filter.event_prefix do
        nil -> query
        prefix -> from(e in query, where: like(e.event, ^"#{prefix}%"))
      end

    query =
      case filter.cycle_id do
        nil ->
          query

        cycle_id ->
          from(e in query,
            where:
              fragment("?->>'cycle_id' LIKE ?", e.metadata, ^"#{cycle_id}%")
          )
      end

    query =
      case filter.span_id do
        nil ->
          query

        span_id ->
          from(e in query,
            where:
              like(e.span_id, ^"#{span_id}%") or
                fragment("?->>'span_id' LIKE ?", e.metadata, ^"#{span_id}%")
          )
      end

    query =
      case text do
        nil ->
          query

        text ->
          pattern = "%#{text}%"

          from(e in query,
            where:
              ilike(e.event, ^pattern) or
                fragment("?::text ILIKE ?", e.measurements, ^pattern) or
                fragment("?::text ILIKE ?", e.metadata, ^pattern)
          )
      end

    query
    |> Froth.Repo.all(log: false)
    |> Enum.map(&Projector.from_row/1)
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(text) do
    case String.trim(to_string(text)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
