defmodule Froth.Telegram.RecentWindow do
  @moduledoc """
  Selects recent Telegram message rows for bot context rendering.

  The primary mode is a time-and-mass window:

  - keep at least the newest `min_hours`
  - try to cover `target_hours`
  - after that, backfill older buckets while under `char_budget`
  - never go older than `backfill_hours`
  - only rotate the front boundary on `bucket_minutes` bucket boundaries

  This gives a recent-history view that is easier to reason about than a hard
  message count. On quiet days the window naturally reaches farther back in
  time. On busy days the oldest buckets fall off in coarse steps rather than
  shifting by one message at a time.

  The legacy count-based anchored window remains available as a fallback for
  bots that still configure `recent_message_limit` and
  `recent_message_anchor_size`.
  """

  alias Froth.Telegram.Queries

  @type row :: %{
          required(:date) => integer(),
          required(:message_id) => integer(),
          required(:sender_id) => integer(),
          required(:inserted_at) => NaiveDateTime.t() | DateTime.t() | nil,
          required(:raw) => map()
        }

  @type time_mass_config :: %{
          required(:target_hours) => pos_integer(),
          required(:min_hours) => pos_integer(),
          required(:backfill_hours) => pos_integer(),
          required(:char_budget) => pos_integer(),
          required(:bucket_minutes) => pos_integer()
        }

  @spec fetch_recent(integer(), integer() | :infinity, keyword()) :: [row()]
  def fetch_recent(chat_id, range_end, opts)
      when is_integer(chat_id) and is_list(opts) do
    session_id = context_session_id(chat_id, opts)
    context_floor_unix = opt_non_negative_int(opts[:context_floor_unix])

    cond do
      is_integer(context_floor_unix) ->
        fetch_rows(chat_id, session_id, context_floor_unix, range_end)

      true ->
        case time_mass_config(opts) do
          {:ok, config} ->
            from_unix =
              max(range_end_unix(range_end) - config.backfill_hours * 3600, 0)

            chat_id
            |> fetch_rows(session_id, from_unix, range_end)
            |> select_rows(range_end, config)

          :error ->
            fetch_recent_legacy(chat_id, session_id, range_end, opts)
        end
    end
  end

  @spec select_rows([row()], integer() | :infinity, time_mass_config()) :: [
          row()
        ]
  def select_rows(rows, range_end, config)
      when is_list(rows) and is_map(config) do
    range_end_unix = range_end_unix(range_end)
    bucket_seconds = config.bucket_minutes * 60
    min_start_unix = max(range_end_unix - config.min_hours * 3600, 0)
    target_start_unix = max(range_end_unix - config.target_hours * 3600, 0)

    rows
    |> bucket_rows(bucket_seconds)
    |> Enum.reverse()
    |> Enum.reduce_while([], fn bucket, selected_rev ->
      candidate_rev = [bucket | selected_rev]
      candidate = Enum.reverse(candidate_rev)
      total_chars = bucket_chars(candidate)
      oldest_bucket_start = oldest_bucket_start(candidate)

      cond do
        oldest_bucket_start > target_start_unix ->
          {:cont, candidate_rev}

        total_chars < config.char_budget ->
          {:cont, candidate_rev}

        true ->
          {:halt, candidate_rev}
      end
    end)
    |> trim_to_budget(min_start_unix, config.char_budget)
    |> Enum.flat_map(& &1.rows)
  end

  @spec time_mass_config(keyword()) :: {:ok, time_mass_config()} | :error
  def time_mass_config(opts) when is_list(opts) do
    with target_hours when is_integer(target_hours) and target_hours > 0 <-
           opt_positive_int(opts[:recent_window_target_hours]),
         min_hours
         when is_integer(min_hours) and min_hours > 0 and
                min_hours <= target_hours <-
           opt_positive_int(opts[:recent_window_min_hours]),
         backfill_hours
         when is_integer(backfill_hours) and backfill_hours >= target_hours <-
           opt_positive_int(opts[:recent_window_backfill_hours]),
         char_budget when is_integer(char_budget) and char_budget > 0 <-
           opt_positive_int(opts[:recent_window_char_budget]),
         bucket_minutes when is_integer(bucket_minutes) and bucket_minutes > 0 <-
           opt_positive_int(opts[:recent_window_bucket_minutes]) do
      {:ok,
       %{
         target_hours: target_hours,
         min_hours: min_hours,
         backfill_hours: backfill_hours,
         char_budget: char_budget,
         bucket_minutes: bucket_minutes
       }}
    else
      _ -> :error
    end
  end

  defp fetch_rows(chat_id, session_id, from_unix, range_end)
       when is_integer(chat_id) do
    cond do
      is_binary(session_id) and session_id != "" ->
        Queries.fetch_session_messages(
          session_id,
          chat_id,
          from_unix,
          range_end
        )

      true ->
        Queries.fetch_messages(chat_id, from_unix, range_end)
    end
  end

  defp fetch_recent_legacy(chat_id, session_id, range_end, opts) do
    recent_limit = opt_positive_int(opts[:recent_message_limit])
    anchor_size = opt_positive_int(opts[:recent_message_anchor_size])

    cond do
      is_binary(session_id) and session_id != "" and is_integer(recent_limit) and
        recent_limit > 0 and
        is_integer(anchor_size) and anchor_size > 1 ->
        keep_count =
          Queries.count_session_messages(session_id, chat_id, 0, range_end)
          |> anchored_keep_count(recent_limit, anchor_size)

        if keep_count > 0 do
          Queries.fetch_recent_session_messages(
            session_id,
            chat_id,
            0,
            range_end,
            keep_count
          )
        else
          []
        end

      is_binary(session_id) and session_id != "" and is_integer(recent_limit) and
          recent_limit > 0 ->
        Queries.fetch_recent_session_messages(
          session_id,
          chat_id,
          0,
          range_end,
          recent_limit
        )

      is_binary(session_id) and session_id != "" ->
        Queries.fetch_session_messages(session_id, chat_id, 0, range_end)

      is_integer(recent_limit) and recent_limit > 0 and
        is_integer(anchor_size) and
          anchor_size > 1 ->
        keep_count =
          Queries.count_messages(chat_id, 0, range_end)
          |> anchored_keep_count(recent_limit, anchor_size)

        if keep_count > 0 do
          Queries.fetch_recent_messages(chat_id, 0, range_end, keep_count)
        else
          []
        end

      is_integer(recent_limit) and recent_limit > 0 ->
        Queries.fetch_recent_messages(chat_id, 0, range_end, recent_limit)

      true ->
        Queries.fetch_messages(chat_id, 0, range_end)
    end
  end

  defp bucket_rows(rows, bucket_seconds)
       when is_list(rows) and is_integer(bucket_seconds) do
    rows
    |> Enum.group_by(
      fn row -> bucket_start(row.date, bucket_seconds) end,
      fn row -> row end
    )
    |> Enum.sort_by(fn {start_unix, _rows} -> start_unix end)
    |> Enum.map(fn {start_unix, bucket_rows} ->
      %{
        start_unix: start_unix,
        rows: bucket_rows,
        chars: rows_chars(bucket_rows)
      }
    end)
  end

  defp trim_to_budget(buckets, min_start_unix, char_budget) do
    trim_to_budget(
      buckets,
      min_start_unix,
      char_budget,
      bucket_chars(buckets)
    )
  end

  defp trim_to_budget([], _min_start_unix, _char_budget, _total_chars), do: []

  defp trim_to_budget(buckets, min_start_unix, char_budget, total_chars) do
    case buckets do
      [%{start_unix: start_unix} | rest]
      when total_chars > char_budget and start_unix < min_start_unix ->
        trim_to_budget(
          rest,
          min_start_unix,
          char_budget,
          total_chars - bucket_chars([hd(buckets)])
        )

      _ ->
        buckets
    end
  end

  defp oldest_bucket_start([%{start_unix: start_unix} | _]), do: start_unix
  defp oldest_bucket_start([]), do: 0

  defp bucket_chars(buckets) when is_list(buckets) do
    Enum.reduce(buckets, 0, fn bucket, acc ->
      acc + Map.get(bucket, :chars, 0)
    end)
  end

  defp rows_chars(rows) when is_list(rows) do
    Enum.reduce(rows, 0, fn row, acc -> acc + row_chars(row) end)
  end

  defp row_chars(%{raw: raw}) when is_map(raw) do
    raw
    |> message_text()
    |> String.length()
  end

  defp row_chars(_row), do: 0

  defp message_text(raw) when is_map(raw) do
    get_in(raw, ["content", "text", "text"]) ||
      get_in(raw, ["content", "caption", "text"]) || ""
  end

  defp anchored_keep_count(total_count, limit, anchor_size)
       when is_integer(total_count) and is_integer(limit) and limit > 0 and
              is_integer(anchor_size) and anchor_size > 1 do
    cond do
      total_count <= limit ->
        total_count

      true ->
        limit + rem(total_count - limit, anchor_size)
    end
  end

  defp range_end_unix(:infinity), do: System.os_time(:second)
  defp range_end_unix(nil), do: System.os_time(:second)
  defp range_end_unix(unix) when is_integer(unix), do: unix

  defp bucket_start(unix, bucket_seconds)
       when is_integer(unix) and is_integer(bucket_seconds) do
    unix - rem(unix, bucket_seconds)
  end

  defp opt_positive_int(value) when is_integer(value) and value > 0, do: value

  defp opt_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp opt_positive_int(_value), do: nil

  defp opt_non_negative_int(value) when is_integer(value) and value >= 0,
    do: value

  defp opt_non_negative_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp opt_non_negative_int(_value), do: nil

  defp context_session_id(chat_id, opts)
       when is_integer(chat_id) and is_list(opts) do
    configured = opt_session_id(opts)

    if chat_id < 0 do
      Queries.default_user_session_id() || configured
    else
      configured
    end
  end

  defp opt_session_id(opts) do
    case opts[:telegram_session_id] do
      id when is_binary(id) and id != "" -> id
      _ -> Queries.default_session_id()
    end
  end
end
