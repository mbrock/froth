defmodule Froth.Tools.Timeline do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  import Ecto.Query

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Repo
  alias Froth.Telegram.BotContext
  alias Froth.Tools.TimelineNavigator

  @default_browse_limit 80
  @default_hit_limit 8
  @max_browse_limit 200
  @max_hit_limit 20
  @default_context_before 3
  @default_context_after 3
  @max_context_window 20
  @max_offset 20_000

  @impl true
  def name, do: "timeline"

  @impl true
  def label, do: "timeline"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Navigate the chat's memory at progressively finer temporal resolution. Start with action=\"index\" to see foundation chapters, closed volumes, detailed weeks, uncovered days, and the unfolding raw tail. Use action=\"search\" to find likely narrative intervals, action=\"open\" with a returned ref to descend volume → week → day, and action=\"messages\" with a week/day ref to inspect primary messages, analyses, and linked cycle traces. Reuse returned refs exactly instead of guessing timestamps. Search defaults to narrative summaries; choose scope=\"messages\" when exact original wording matters.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["index", "search", "open", "messages"],
            "description" =>
              "Navigation move. Defaults intelligently: no input → index, ref → open, query → search, and date/sender/offset fields → messages."
          },
          "ref" => %{
            "type" => "string",
            "description" =>
              "Stable opaque ref returned by index, search, or open, such as volume:208, week:185, day:207, or foundation:ch01-the-founding."
          },
          "detail" => %{
            "type" => "string",
            "enum" => ["outline", "full"],
            "description" =>
              "For open: outline returns a compact synopsis and child intervals; full returns the complete narrative text. Defaults to outline."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["narrative", "messages", "all"],
            "description" =>
              "For search: narrative searches chapters/volumes/weeks/days, messages searches exact Telegram wording with surrounding context, and all returns both. Defaults to narrative."
          },
          "query" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Case-insensitive literal terms or short phrases, OR'd together. Supply several plausible terms when searching narrative memory."
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
          "offset" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" =>
              "For paginating messages within an interval. Start at 0 and reuse next_offset from the result."
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
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    chat_id = ctx_chat_id(ctx)
    action = resolve_action(input)

    case action do
      "index" ->
        {:ok, TimelineNavigator.index(chat_id)}

      "search" ->
        execute_search(chat_id, input, render_opts(ctx))

      "open" ->
        execute_open(chat_id, input)

      "messages" ->
        execute_messages(chat_id, input, render_opts(ctx))

      _ ->
        {:error, "action must be one of index, search, open, or messages"}
    end
  end

  def execute(%Context{}, %ToolUse{}, _hooks),
    do: {:error, "Could not load timeline for the given input."}

  defp execute_search(chat_id, input, render_opts) do
    queries = search_phrases(input["query"])
    scope = input["scope"] || "narrative"

    cond do
      queries == [] ->
        {:error, "query must contain at least one non-empty search term"}

      scope == "narrative" ->
        {:ok, TimelineNavigator.search(chat_id, queries, input)}

      scope == "messages" ->
        with {:ok, ranged_input} <- apply_ref_range(chat_id, input) do
          {:ok,
           render_message_search(
             chat_id,
             ranged_input,
             queries,
             render_opts
           )}
        end

      scope == "all" ->
        with {:ok, ranged_input} <- apply_ref_range(chat_id, input) do
          narrative = TimelineNavigator.search(chat_id, queries, input)

          messages =
            render_message_search(
              chat_id,
              ranged_input,
              queries,
              render_opts
            )

          {:ok, narrative <> "\n\n" <> messages}
        end

      true ->
        {:error, "scope must be narrative, messages, or all"}
    end
  end

  defp execute_open(chat_id, input) do
    ref = input["ref"]
    detail = input["detail"] || "outline"

    cond do
      not is_binary(ref) or String.trim(ref) == "" ->
        {:error, "ref is required for open"}

      detail not in ["outline", "full"] ->
        {:error, "detail must be outline or full"}

      true ->
        TimelineNavigator.open(chat_id, String.trim(ref), detail)
    end
  end

  defp execute_messages(chat_id, input, render_opts) do
    with {:ok, ranged_input} <- apply_ref_range(chat_id, input) do
      queries = search_phrases(ranged_input["query"])

      if queries == [] do
        {rows, has_more?, offset} = browse_rows(chat_id, ranged_input)

        {:ok,
         render_message_window(
           chat_id,
           rows,
           ranged_input,
           render_opts,
           has_more?,
           offset
         )}
      else
        {:ok,
         render_message_search(chat_id, ranged_input, queries, render_opts)}
      end
    end
  end

  defp apply_ref_range(chat_id, %{"ref" => ref} = input)
       when is_binary(ref) do
    case TimelineNavigator.resolve_range(chat_id, String.trim(ref)) do
      {:ok, {from_unix, to_unix}} ->
        {:ok,
         input
         |> Map.put("__from_unix", from_unix)
         |> Map.put("__to_unix", to_unix)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_ref_range(_chat_id, input), do: {:ok, input}

  defp render_message_search(chat_id, input, queries, render_opts) do
    rows = search_rows(chat_id, input, queries)

    case rows do
      [] ->
        """
        <timeline-search scope="messages">
          <queries>#{xml_text(inspect(queries))}</queries>
          No exact message matches. Try narrative scope or several shorter terms.
        </timeline-search>
        """
        |> String.trim()

      _ ->
        """
        <timeline-search scope="messages">
          <queries>#{xml_text(inspect(queries))}</queries>
        #{BotContext.render_for_messages(chat_id, rows, render_opts)}
          <next>
            Use a returned message timestamp to browse a tighter interval, or
            search narrative scope to recover the larger arc around this scene.
          </next>
        </timeline-search>
        """
        |> String.trim()
    end
  end

  defp render_message_window(
         _chat_id,
         [],
         input,
         _render_opts,
         _has_more?,
         offset
       ) do
    """
    <timeline-messages ref=#{xml_attr(input["ref"] || "")} offset="#{offset}" returned="0">
      No timeline entries found for this interval.
    </timeline-messages>
    """
    |> String.trim()
  end

  defp render_message_window(
         chat_id,
         rows,
         input,
         render_opts,
         has_more?,
         offset
       ) do
    next_offset = offset + length(rows)

    next =
      if has_more? do
        """
          <next offset="#{next_offset}">
            Call messages again with the same ref/range and offset=#{next_offset}.
          </next>
        """
      else
        "  <next state=\"end-of-interval\" />"
      end

    """
    <timeline-messages ref=#{xml_attr(input["ref"] || "")} offset="#{offset}" returned="#{length(rows)}">
    #{BotContext.render_for_messages(chat_id, rows, render_opts)}
    #{next}
    </timeline-messages>
    """
    |> String.trim()
  end

  defp browse_rows(chat_id, input)
       when is_integer(chat_id) and is_map(input) do
    from_unix = input["__from_unix"] || parse_datetime(input["from_date"])
    to_unix = input["__to_unix"] || parse_to_datetime(input["to_date"])
    page_offset = bounded_offset(input["offset"])

    limit =
      bounded_integer(
        input["limit"],
        @default_browse_limit,
        1,
        @max_browse_limit
      )

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
          |> with_offset(page_offset)
          |> limit(^(limit + 1))
          |> Repo.all(log: false)

        _ ->
          query
          |> order_by([m],
            desc: m.date,
            desc: m.inserted_at,
            desc: m.message_id
          )
          |> with_offset(page_offset)
          |> limit(^(limit + 1))
          |> Repo.all(log: false)
      end

    has_more? = length(rows) > limit

    rows =
      rows
      |> Enum.take(limit)
      |> then(fn selected ->
        if is_integer(from_unix), do: selected, else: Enum.reverse(selected)
      end)
      |> dedupe_messages()

    {rows, has_more?, page_offset}
  end

  defp with_offset(query, page_offset) when is_integer(page_offset),
    do: from(m in query, offset: ^page_offset)

  defp search_rows(chat_id, input, queries)
       when is_integer(chat_id) and is_map(input) and is_list(queries) do
    from_unix = input["__from_unix"] || parse_datetime(input["from_date"])
    to_unix = input["__to_unix"] || parse_to_datetime(input["to_date"])

    hit_limit =
      bounded_integer(input["limit"], @default_hit_limit, 1, @max_hit_limit)

    before_count =
      bounded_integer(
        input["before"],
        @default_context_before,
        0,
        @max_context_window
      )

    after_count =
      bounded_integer(
        input["after"],
        @default_context_after,
        0,
        @max_context_window
      )

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
      before_rows =
        surrounding_rows(
          chat_id,
          from_unix,
          to_unix,
          hit,
          before_count,
          :before
        )

      after_rows =
        surrounding_rows(
          chat_id,
          from_unix,
          to_unix,
          hit,
          after_count,
          :after
        )

      before_rows ++ [hit] ++ after_rows
    end)
    |> dedupe_messages()
    |> Enum.sort_by(&message_sort_key/1)
  end

  defp surrounding_rows(_chat_id, _from_unix, _to_unix, _hit, 0, _direction),
    do: []

  defp surrounding_rows(chat_id, from_unix, to_unix, hit, count, :before) do
    before_to_unix =
      if is_integer(to_unix) and to_unix < hit.date,
        do: to_unix,
        else: hit.date

    chat_id
    |> base_message_query()
    |> maybe_filter_from_date(from_unix)
    |> maybe_filter_to_date(before_to_unix)
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
    {msg.date || 0, msg.inserted_at || ~U[1970-01-01 00:00:00Z],
     msg.message_id || 0}
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

  defp render_opts(%Context{
         surface: %{session_id: session_id},
         bot_config: bot_config
       }) do
    []
    |> maybe_put_render_opt(:telegram_session_id, session_id)
    |> maybe_put_render_opt(:bot_id, Map.get(bot_config || %{}, :id))
  end

  defp maybe_put_render_opt(opts, _key, nil), do: opts
  defp maybe_put_render_opt(opts, _key, ""), do: opts

  defp maybe_put_render_opt(opts, key, value),
    do: Keyword.put(opts, key, value)

  defp resolve_action(%{"action" => action}) when is_binary(action),
    do: action

  defp resolve_action(input) do
    cond do
      is_binary(input["ref"]) ->
        "open"

      search_phrases(input["query"]) != [] ->
        "search"

      Enum.any?(
        [
          "from_date",
          "to_date",
          "sender_id",
          "before",
          "after",
          "limit",
          "offset"
        ],
        &Map.has_key?(input, &1)
      ) ->
        "messages"

      true ->
        "index"
    end
  end

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
       when is_integer(default) and is_integer(lower_bound) and
              is_integer(upper_bound) do
    parsed =
      case parse_integer(value) do
        integer when integer >= lower_bound -> integer
        _ -> default
      end

    cond do
      parsed < lower_bound -> lower_bound
      parsed > upper_bound -> upper_bound
      true -> parsed
    end
  end

  defp bounded_offset(value) do
    parsed = parse_integer(value)

    cond do
      not is_integer(parsed) -> 0
      parsed < 0 -> 0
      parsed > @max_offset -> @max_offset
      true -> parsed
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

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
              {:ok, date} ->
                date
                |> DateTime.new!(~T[00:00:00], "Etc/UTC")
                |> DateTime.to_unix()

              _ ->
                nil
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

  defp ctx_chat_id(%Context{surface: %{chat_id: chat_id}})
       when is_integer(chat_id), do: chat_id

  defp ctx_chat_id(_ctx), do: 0

  defp xml_attr(value) do
    escaped =
      value
      |> to_string()
      |> xml_text()
      |> String.replace("\"", "&quot;")

    ~s("#{escaped}")
  end

  defp xml_text(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
