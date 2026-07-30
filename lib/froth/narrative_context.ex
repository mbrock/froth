defmodule Froth.NarrativeContext do
  @moduledoc """
  Selects a contiguous, resolution-aware narrative inheritance for summaries.

  Daily summaries inherit the latest closed structural chapter plus every
  daily summary after it. Weekly summaries inherit the latest closed volume
  plus the detailed weekly chapters after it. The original summaries remain
  stored; only the resolution presented to the next writer changes.
  """

  import Ecto.Query

  alias Froth.{ChatSummary, Repo}

  @volume_kind "chronicle_volume"
  @weekly_kind "weekly_chronicle"
  @fallback_daily_limit 7

  def for_daily_summary(chat_id, before_unix)
      when is_integer(chat_id) and is_integer(before_unix) do
    case latest_structural_anchor(chat_id, before_unix) do
      nil ->
        daily_summaries(chat_id, 0, before_unix)
        |> Enum.take(-@fallback_daily_limit)

      anchor ->
        [anchor | daily_summaries(chat_id, anchor.to_date, before_unix)]
    end
  end

  def for_weekly_summary(chat_id, before_unix)
      when is_integer(chat_id) and is_integer(before_unix) do
    case latest_volume(chat_id, before_unix) do
      nil ->
        weekly_summaries(chat_id, 0, before_unix)

      volume ->
        [volume | weekly_summaries(chat_id, volume.to_date, before_unix)]
    end
  end

  def weekly_chapter_count(chat_id, before_unix)
      when is_integer(chat_id) and is_integer(before_unix) do
    Repo.aggregate(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.to_date <= ^before_unix,
        where: fragment("?->>'kind' = ?", s.metadata, @weekly_kind)
      ),
      :count,
      :id
    )
  end

  def volume?(%ChatSummary{metadata: %{"kind" => @volume_kind}}), do: true
  def volume?(_summary), do: false

  defp latest_structural_anchor(chat_id, before_unix) do
    Repo.one(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.to_date <= ^before_unix,
        where:
          fragment(
            "?->>'kind' IN (?, ?)",
            s.metadata,
            @volume_kind,
            @weekly_kind
          ),
        order_by: [desc: s.to_date, desc: s.inserted_at],
        limit: 1
      ),
      log: false
    )
  end

  defp latest_volume(chat_id, before_unix) do
    Repo.one(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.to_date <= ^before_unix,
        where: fragment("?->>'kind' = ?", s.metadata, @volume_kind),
        order_by: [desc: s.to_date, desc: s.inserted_at],
        limit: 1
      ),
      log: false
    )
  end

  defp daily_summaries(chat_id, from_unix, before_unix) do
    Repo.all(
      from(s in ChatSummary,
        where:
          s.chat_id == ^chat_id and s.from_date >= ^from_unix and
            s.to_date <= ^before_unix,
        where: s.from_date != s.to_date and s.to_date - s.from_date <= 86_400,
        order_by: [asc: s.from_date, desc: s.inserted_at]
      ),
      log: false
    )
    |> longest_per_start()
  end

  defp weekly_summaries(chat_id, from_unix, before_unix) do
    Repo.all(
      from(s in ChatSummary,
        where:
          s.chat_id == ^chat_id and s.from_date >= ^from_unix and
            s.to_date <= ^before_unix,
        where: fragment("?->>'kind' = ?", s.metadata, @weekly_kind),
        order_by: [asc: s.from_date]
      ),
      log: false
    )
  end

  defp longest_per_start(summaries) do
    summaries
    |> Enum.group_by(& &1.from_date)
    |> Enum.map(fn {_from_date, rows} ->
      Enum.max_by(rows, &String.length(&1.summary_text))
    end)
    |> Enum.sort_by(& &1.from_date)
  end
end
