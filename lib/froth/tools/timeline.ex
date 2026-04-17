defmodule Froth.Tools.Timeline do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  import Ecto.Query

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Repo
  alias Froth.Telegram.BotContext

  @default_browse_limit 80
  @default_hit_limit 8
  @max_browse_limit 200
  @max_hit_limit 20
  @default_context_before 3
  @default_context_after 3
  @max_context_window 20

  @impl true
  def name, do: "timeline"

  @impl true
  def label, do: "timeline"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Query chat history through the same context renderer the bot already uses for normal prompt history. In browse mode, it returns a chronological slice of messages, analyses, and linked cycle traces. In search mode, it finds literal phrase matches and includes surrounding context messages. Use this as the unified way to inspect the chat timeline.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Optional literal phrases to search for. Items are OR'd together, case-insensitively."
          },
          "from_date" => %{
            "type" => "string",
            "description" =>
              "Optional ISO 8601 start date or datetime, for example 2026-02-10 or 2026-02-10T14:30:00."
          },
          "to_date" => %{
            "type" => "string",
            "description" =>
              "Optional ISO 8601 end date or datetime. Dates are treated as exclusive upper bounds at the next midnight."
          },
          "sender_id" => %{
            "type" => "integer",
            "description" =>
              "Optional Telegram sender ID. In search mode this filters hits, while surrounding context may still include other senders."
          },
          "before" => %{
            "type" => "integer",
            "description" =>
              "For search mode, how many context messages to include before each hit. Defaults to 3."
          },
          "after" => %{
            "type" => "integer",
            "description" =>
              "For search mode, how many context messages to include after each hit. Defaults to 3."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Maximum browse messages or search hits to include. Defaults to 80 in browse mode and 8 in search mode."
          }
        },
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks) when is_map(input) do
    chat_id = ctx_chat_id(ctx)
    render_opts = render_opts(ctx)
    queries = search_phrases(input["query"])

    rows =
      if queries == [] do
        browse_rows(chat_id, input)
      else
        search_rows(chat_id, input, queries)
      end

    case rows do
      [] -> {:ok, empty_result_message(queries)}
      rows -> {:ok, BotContext.render_for_messages(chat_id, rows, render_opts)}
    end
  end

  def execute(%Context{}, %ToolUse{}, _hooks),
    do: {:error, "Could not load timeline for the given input."}

  defp browse_rows(chat_id, input) when is_integer(chat_id) and is_map(input) do
    from_unix = parse_datetime(input["from_date"])
    to_unix = parse_to_datetime(input["to_date"])
    limit = bounded_integer(input["limit"], @default_browse_limit, 1, @max_browse_limit)

    query =
      chat_id
      |> base_message_query()
      |> maybe_filter_to_date(to_unix)
      |> maybe_filter_sender(input["sender_id"])

    query =
      case from_unix do
        unix when is_integer(unix) -> from(m in query, where: m.date >= ^unix)
        _ -> query
      end

    rows =
      case from_unix do
        unix when is_integer(unix) ->
          query
          |> order_by([m], asc: m.date, asc: m.inserted_at, asc: m.message_id)
          |> limit(^limit)
          |> Repo.all(log: false)

        _ ->
          query
          |> order_by([m], desc: m.date, desc: m.inserted_at, desc: m.message_id)
          |> limit(^limit)
          |> Repo.all(log: false)
          |> Enum.reverse()
      end

    dedupe_messages(rows)
  end

  defp search_rows(chat_id, input, queries)
       when is_integer(chat_id) and is_map(input) and is_list(queries) do
    from_unix = parse_datetime(input["from_date"])
    to_unix = parse_to_datetime(input["to_date"])
    hit_limit = bounded_integer(input["limit"], @default_hit_limit, 1, @max_hit_limit)

    before_count =
      bounded_integer(input["before"], @default_context_before, 0, @max_context_window)

    after_count = bounded_integer(input["after"], @default_context_after, 0, @max_context_window)

    hit_query =
      chat_id
      |> base_message_query()
      |> maybe_filter_from_date(from_unix)
      |> maybe_filter_to_date(to_unix)
      |> maybe_filter_sender(input["sender_id"])
      |> where(^search_dynamic(queries))
      |> order_by([m], desc: m.date, desc: m.inserted_at, desc: m.message_id)
      |> limit(^hit_limit)

    hits =
      hit_query
      |> Repo.all(log: false)
      |> dedupe_messages()
      |> Enum.reverse()

    hits
    |> Enum.flat_map(fn hit ->
      before_rows = surrounding_rows(chat_id, from_unix, to_unix, hit, before_count, :before)
      after_rows = surrounding_rows(chat_id, from_unix, to_unix, hit, after_count, :after)
      before_rows ++ [hit] ++ after_rows
    end)
    |> dedupe_messages()
    |> Enum.sort_by(&message_sort_key/1)
  end

  defp surrounding_rows(_chat_id, _from_unix, _to_unix, _hit, 0, _direction), do: []

  defp surrounding_rows(chat_id, from_unix, to_unix, hit, count, :before) do
    chat_id
    |> base_message_query()
    |> maybe_filter_from_date(from_unix)
    |> maybe_filter_to_date(min(to_unix || hit.date + 1, hit.date))
    |> where([m], m.date < ^hit.date)
    |> order_by([m], desc: m.date, desc: m.inserted_at, desc: m.message_id)
    |> limit(^count)
    |> Repo.all(log: false)
    |> Enum.reverse()
    |> dedupe_messages()
  end

  defp surrounding_rows(chat_id, from_unix, to_unix, hit, count, :after) do
    query =
      chat_id
      |> base_message_query()
      |> maybe_filter_from_date(from_unix)
      |> maybe_filter_to_date(to_unix)
      |> where([m], m.date > ^hit.date)
      |> order_by([m], asc: m.date, asc: m.inserted_at, asc: m.message_id)
      |> limit(^count)

    query
    |> Repo.all(log: false)
    |> dedupe_messages()
  end

  defp base_message_query(chat_id) when is_integer(chat_id) do
    from(m in "telegram_messages",
      where: m.chat_id == ^chat_id,
      select: %{
        date: m.date,
        sender_id: m.sender_id,
        message_id: m.message_id,
        inserted_at: m.inserted_at,
        raw: m.raw
      }
    )
  end

  defp maybe_filter_from_date(query, unix) when is_integer(unix),
    do: from(m in query, where: m.date >= ^unix)

  defp maybe_filter_from_date(query, _unix), do: query

  defp maybe_filter_to_date(query, unix) when is_integer(unix),
    do: from(m in query, where: m.date < ^unix)

  defp maybe_filter_to_date(query, _unix), do: query

  defp maybe_filter_sender(query, sender_id) when is_integer(sender_id),
    do: from(m in query, where: m.sender_id == ^sender_id)

  defp maybe_filter_sender(query, _sender_id), do: query

  defp search_dynamic([phrase | rest]) do
    Enum.reduce(rest, search_clause(phrase), fn next_phrase, dynamic ->
      dynamic([m], ^dynamic or ^search_clause(next_phrase))
    end)
  end

  defp search_dynamic([]), do: dynamic(true)

  defp search_clause(phrase) when is_binary(phrase) do
    trimmed = String.trim(phrase)

    dynamic(
      [m],
      fragment(
        "strpos(lower(coalesce(?->'content'->'text'->>'text', ?->'content'->'caption'->>'text', '')), lower(?)) > 0",
        m.raw,
        m.raw,
        ^trimmed
      )
    )
  end

  defp message_sort_key(msg) do
    {msg.date || 0, msg.inserted_at || ~U[1970-01-01 00:00:00Z], msg.message_id || 0}
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

  defp render_opts(%Context{surface: %{session_id: session_id}, bot_config: bot_config}) do
    []
    |> maybe_put_render_opt(:telegram_session_id, session_id)
    |> maybe_put_render_opt(:bot_id, Map.get(bot_config || %{}, :id))
  end

  defp maybe_put_render_opt(opts, _key, nil), do: opts
  defp maybe_put_render_opt(opts, _key, ""), do: opts
  defp maybe_put_render_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp empty_result_message([]), do: "No timeline entries found for the given input."

  defp empty_result_message(queries),
    do: "No timeline entries found matching #{inspect(queries)}."

  defp search_phrases(values) when is_list(values) do
    values
    |> Enum.map(&normalize_phrase/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp search_phrases(_), do: []

  defp normalize_phrase(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_phrase(_), do: nil

  defp bounded_integer(value, default, lower_bound, upper_bound)
       when is_integer(default) and is_integer(lower_bound) and is_integer(upper_bound) do
    parsed = parse_positive_integer(value) || default
    parsed |> max(lower_bound) |> min(upper_bound)
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_positive_integer(_), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} ->
            ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

          _ ->
            case Date.from_iso8601(value) do
              {:ok, date} -> date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
              _ -> nil
            end
        end
    end
  end

  defp parse_to_datetime(nil), do: nil
  defp parse_to_datetime(""), do: nil

  defp parse_to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} ->
        parse_datetime(value)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, _} ->
            parse_datetime(value)

          _ ->
            case parse_datetime(value) do
              nil -> nil
              unix -> unix + 86_400
            end
        end
    end
  end

  defp ctx_chat_id(%Context{surface: %{chat_id: chat_id}}) when is_integer(chat_id), do: chat_id
  defp ctx_chat_id(_ctx), do: 0
end
