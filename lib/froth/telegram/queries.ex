defmodule Froth.Telegram.Queries do
  @moduledoc """
  Data-fetching queries used by the Telegram bot context builder and friends.
  """

  import Ecto.Query

  alias Froth.{Analysis, ChatSummary, Repo}
  alias Froth.Agent.Cycle
  alias Froth.Telegram.CycleLink

  # ── messages ──────────────────────────────────────────────────────

  def fetch_messages(chat_id, from_unix, to_unix)
      when is_integer(chat_id) and is_integer(from_unix) and is_integer(to_unix) do
    from(m in "telegram_messages",
      where: m.chat_id == ^chat_id and m.date >= ^from_unix and m.date < ^to_unix,
      order_by: [asc: m.date, asc: m.inserted_at],
      select: %{
        date: m.date,
        sender_id: m.sender_id,
        message_id: m.message_id,
        inserted_at: m.inserted_at,
        raw: m.raw
      }
    )
    |> Repo.all(log: false)
    |> dedupe_messages()
  end

  def fetch_messages(chat_id, from_unix, :infinity)
      when is_integer(chat_id) and is_integer(from_unix) do
    from(m in "telegram_messages",
      where: m.chat_id == ^chat_id and m.date >= ^from_unix,
      order_by: [asc: m.date, asc: m.inserted_at],
      select: %{
        date: m.date,
        sender_id: m.sender_id,
        message_id: m.message_id,
        inserted_at: m.inserted_at,
        raw: m.raw
      }
    )
    |> Repo.all(log: false)
    |> dedupe_messages()
  end

  defp dedupe_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {msg, idx}, acc ->
      Map.put(acc, msg.message_id, {idx, msg})
    end)
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # ── daily summaries ──────────────────────────────────────────────

  def daily_summaries(chat_id, before_unix \\ nil) when is_integer(chat_id) do
    from(s in ChatSummary,
      where: s.chat_id == ^chat_id and s.from_date != s.to_date,
      where: fragment("? - ? <= 86400", s.to_date, s.from_date),
      order_by: [asc: s.from_date],
      select: %{from_date: s.from_date, to_date: s.to_date, summary_text: s.summary_text}
    )
    |> maybe_before_unix(before_unix)
    |> Repo.all(log: false)
  end

  defp maybe_before_unix(query, nil), do: query

  defp maybe_before_unix(query, unix) when is_integer(unix),
    do: from(s in query, where: s.to_date <= ^unix)

  # ── analyses ─────────────────────────────────────────────────────

  def analyses_for_messages(_chat_id, []), do: %{}

  def analyses_for_messages(chat_id, message_ids)
      when is_integer(chat_id) and is_list(message_ids) do
    Repo.all(
      from(a in Analysis,
        where: a.chat_id == ^chat_id and a.message_id in ^message_ids,
        select: %{
          id: a.id,
          type: a.type,
          message_id: a.message_id,
          analysis_text: a.analysis_text
        }
      ),
      log: false
    )
    |> Enum.group_by(& &1.message_id)
  end

  # ── cycle traces ─────────────────────────────────────────────────

  def cycle_traces_for_messages(chat_id, message_ids, opts \\ [])
  def cycle_traces_for_messages(_chat_id, [], _opts), do: %{}

  def cycle_traces_for_messages(chat_id, message_ids, opts)
      when is_integer(chat_id) and is_list(message_ids) and is_list(opts) do
    query =
      from(l in CycleLink,
        join: c in Cycle,
        on: c.id == l.cycle_id,
        where: l.chat_id == ^chat_id and l.reply_to in ^message_ids,
        order_by: [asc: c.inserted_at],
        select: %{message_id: l.reply_to, cycle_id: l.cycle_id, inserted_at: c.inserted_at}
      )

    query =
      case opts[:bot_id] do
        bot_id when is_binary(bot_id) and bot_id != "" ->
          from([l, c] in query, where: l.bot_id == ^bot_id)

        _ ->
          query
      end

    Repo.all(query, log: false)
    |> Enum.group_by(& &1.message_id)
  end

  # ── session config ───────────────────────────────────────────────

  def enabled_session_ids do
    Repo.all(
      from(s in Froth.Telegram.SessionConfig,
        where: s.enabled == true,
        order_by: [asc: s.id],
        select: s.id
      ),
      log: false
    )
  end

  def default_session_id do
    Repo.one(
      from(s in Froth.Telegram.SessionConfig,
        where: s.enabled == true,
        order_by: [asc: s.id],
        select: s.id,
        limit: 1
      ),
      log: false
    )
  end
end
