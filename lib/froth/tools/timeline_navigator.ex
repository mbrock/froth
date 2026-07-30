defmodule Froth.Tools.TimelineNavigator do
  @moduledoc false

  import Ecto.Query

  alias Froth.{ChatSummary, Repo}

  @volume_kind "chronicle_volume"
  @weekly_kind "weekly_chronicle"
  @default_search_limit 12
  @max_search_limit 30

  def index(chat_id) when is_integer(chat_id) do
    foundations = foundation_entries()
    volumes = summaries_of_kind(chat_id, @volume_kind)
    volume_end = latest_end(volumes)

    weeks =
      chat_id
      |> summaries_of_kind(@weekly_kind)
      |> Enum.filter(&after_boundary?(&1, volume_end))

    week_end = latest_end(weeks) || volume_end

    days =
      chat_id
      |> daily_summaries(week_end || 0, nil)
      |> longest_per_start()

    raw_start = latest_end(days) || week_end

    """
    <timeline-index>
      <instructions>
        Start broad, then descend only as far as the question requires.
        Reuse refs exactly: open a volume to see its source weeks, open a week
        to see its source days, and use messages with a week or day ref to read
        primary chat evidence. Search defaults to narrative summaries; set
        scope="messages" only when exact wording matters.
        The intended descent is volume → week → day → messages.
      </instructions>

    #{render_foundation_layer(foundations)}
    #{render_summary_layer("volumes", volumes)}
    #{render_summary_layer("detailed-weeks", weeks)}
    #{render_summary_layer("uncovered-days", days)}
    #{render_raw_tail(raw_start)}
    </timeline-index>
    """
    |> String.trim()
  end

  def search(chat_id, queries, input)
      when is_integer(chat_id) and is_list(queries) and is_map(input) do
    limit = bounded_limit(input["limit"])
    from_unix = parse_datetime(input["from_date"])
    to_unix = parse_to_datetime(input["to_date"])

    foundation_hits =
      foundation_entries()
      |> Enum.filter(&matches?(&1.text, queries))
      |> Enum.map(&Map.put(&1, :layer, :foundation))

    summary_hits =
      chat_id
      |> narrative_summaries(from_unix, to_unix, queries)
      |> longest_daily_versions()
      |> Enum.map(&summary_entry/1)

    hits =
      (foundation_hits ++ summary_hits)
      |> Enum.sort_by(&search_sort_key/1)
      |> Enum.take(limit)

    case hits do
      [] ->
        "No narrative intervals found matching #{inspect(queries)}."

      _ ->
        """
        <timeline-search scope="narrative">
          <queries>#{xml_text(inspect(queries))}</queries>
        #{Enum.map_join(hits, "\n", &render_search_hit(&1, queries))}
          <next>
            Open a promising ref with detail="outline". Descend through its
            child refs before reading messages. If the summaries use different
            wording, search again with several short alternative terms.
          </next>
        </timeline-search>
        """
        |> String.trim()
    end
  end

  def open(chat_id, ref, detail)
      when is_integer(chat_id) and is_binary(ref) and
             detail in ["outline", "full"] do
    with {:ok, entry} <- resolve(chat_id, ref) do
      {:ok, render_open(entry, chat_id, detail)}
    end
  end

  def resolve_range(chat_id, ref)
      when is_integer(chat_id) and is_binary(ref) do
    with {:ok, entry} <- resolve(chat_id, ref),
         {:ok, from_unix, to_unix} <- entry_range(entry) do
      {:ok, {from_unix, to_unix}}
    end
  end

  defp resolve(_chat_id, "foundation:" <> slug) do
    case Enum.find(foundation_entries(), &(&1.slug == slug)) do
      nil ->
        {:error, "Unknown timeline ref #{inspect("foundation:" <> slug)}."}

      entry ->
        {:ok, Map.put(entry, :layer, :foundation)}
    end
  end

  defp resolve(chat_id, ref) do
    with [kind, id_text] <- String.split(ref, ":", parts: 2),
         true <- kind in ["volume", "week", "day"],
         {id, ""} <- Integer.parse(id_text),
         %ChatSummary{} = summary <-
           Repo.get_by(ChatSummary, id: id, chat_id: chat_id),
         true <- ref_kind(summary) == kind do
      {:ok, summary_entry(summary)}
    else
      _ -> {:error, "Unknown or mismatched timeline ref #{inspect(ref)}."}
    end
  end

  defp render_open(%{layer: :foundation} = entry, _chat_id, detail) do
    body =
      if detail == "full", do: entry.text, else: excerpt(entry.text, [], 900)

    """
    <timeline-entry ref=#{xml_attr(entry.ref)} layer="foundation" detail=#{xml_attr(detail)}>
      <title>#{xml_text(entry.title)}</title>
      <content>
    #{xml_text(body)}
      </content>
      <next>Use detail="full" to read the complete chapter.</next>
    </timeline-entry>
    """
    |> String.trim()
  end

  defp render_open(%{summary: summary} = entry, chat_id, detail) do
    children = child_entries(chat_id, summary)

    body =
      if detail == "full" do
        summary.summary_text
      else
        excerpt(summary.summary_text, [], 1_100)
      end

    child_text =
      case children do
        [] ->
          "  <children />"

        _ ->
          "  <children>\n#{Enum.map_join(children, "\n", &render_entry/1)}\n  </children>"
      end

    next =
      case entry.layer do
        :volume ->
          "Open a child week ref; use detail=\"full\" only if this volume itself is the needed resolution."

        :week ->
          "Open a child day ref, or call messages with this week ref for primary evidence."

        :day ->
          "Call messages with this day ref to read the primary chat evidence."
      end

    """
    <timeline-entry ref=#{xml_attr(entry.ref)} layer=#{xml_attr(entry.layer)} range=#{xml_attr(entry.range)} detail=#{xml_attr(detail)}>
      <title>#{xml_text(entry.title)}</title>
      <content>
    #{xml_text(body)}
      </content>
    #{child_text}
      <next>#{next}</next>
    </timeline-entry>
    """
    |> String.trim()
  end

  defp child_entries(chat_id, %ChatSummary{} = summary) do
    ids = get_in(summary.metadata || %{}, ["source_summary_ids"]) || []

    children =
      if ids == [] do
        derived_children(chat_id, summary)
      else
        by_id =
          Repo.all(
            from(s in ChatSummary,
              where: s.chat_id == ^chat_id and s.id in ^ids
            ),
            log: false
          )
          |> Map.new(&{&1.id, &1})

        Enum.flat_map(ids, fn id ->
          case Map.get(by_id, id) do
            nil -> []
            child -> [child]
          end
        end)
      end

    children
    |> longest_daily_versions()
    |> Enum.map(&summary_entry/1)
  end

  defp derived_children(chat_id, summary) do
    case ref_kind(summary) do
      "volume" ->
        Repo.all(
          from(s in ChatSummary,
            where:
              s.chat_id == ^chat_id and s.from_date >= ^summary.from_date and
                s.to_date <= ^summary.to_date,
            where: fragment("?->>'kind' = ?", s.metadata, @weekly_kind),
            order_by: [asc: s.from_date]
          ),
          log: false
        )

      "week" ->
        daily_summaries(chat_id, summary.from_date, summary.to_date)

      _ ->
        []
    end
  end

  defp narrative_summaries(chat_id, from_unix, to_unix, queries) do
    dynamic_query =
      Enum.reduce(queries, dynamic(false), fn phrase, acc ->
        pattern = "%#{escape_like(phrase)}%"

        dynamic(
          [s],
          ^acc or ilike(s.summary_text, ^pattern)
        )
      end)

    from(s in ChatSummary,
      where: s.chat_id == ^chat_id,
      where: ^dynamic_query,
      order_by: [desc: s.from_date, desc: s.inserted_at]
    )
    |> maybe_summary_from(from_unix)
    |> maybe_summary_to(to_unix)
    |> limit(80)
    |> Repo.all(log: false)
  end

  defp maybe_summary_from(query, unix) when is_integer(unix),
    do: from(s in query, where: s.to_date > ^unix)

  defp maybe_summary_from(query, _unix), do: query

  defp maybe_summary_to(query, unix) when is_integer(unix),
    do: from(s in query, where: s.from_date < ^unix)

  defp maybe_summary_to(query, _unix), do: query

  defp summaries_of_kind(chat_id, kind) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        where: fragment("?->>'kind' = ?", s.metadata, ^kind),
        order_by: [asc: s.from_date]
      ),
      log: false
    )
  end

  defp daily_summaries(chat_id, from_unix, to_unix) do
    query =
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.from_date >= ^from_unix,
        where: s.from_date != s.to_date and s.to_date - s.from_date <= 86_400,
        order_by: [asc: s.from_date, desc: s.inserted_at]
      )

    query =
      if is_integer(to_unix) do
        from(s in query, where: s.to_date <= ^to_unix)
      else
        query
      end

    Repo.all(query, log: false)
  end

  defp longest_daily_versions(entries) do
    {daily, structural} =
      Enum.split_with(entries, &(ref_kind(&1) == "day"))

    structural ++ longest_per_start(daily)
  end

  defp longest_per_start(summaries) do
    summaries
    |> Enum.group_by(& &1.from_date)
    |> Enum.map(fn {_from_date, rows} ->
      Enum.max_by(rows, &String.length(&1.summary_text))
    end)
    |> Enum.sort_by(& &1.from_date)
  end

  defp summary_entry(summary) do
    kind = ref_kind(summary)
    layer = %{"volume" => :volume, "week" => :week, "day" => :day}[kind]

    %{
      layer: layer,
      ref: "#{kind}:#{summary.id}",
      title: title(summary.summary_text),
      text: summary.summary_text,
      range: format_range(summary.from_date, summary.to_date),
      from_unix: summary.from_date,
      to_unix: summary.to_date,
      message_count: summary.message_count,
      summary: summary
    }
  end

  defp foundation_entries do
    :froth
    |> Application.app_dir("priv/chronicle/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      text = File.read!(path)
      slug = Path.basename(path, ".md")

      %{
        slug: slug,
        ref: "foundation:#{slug}",
        title: title(text),
        text: text,
        range: foundation_range(text)
      }
    end)
  end

  defp foundation_range(text) do
    case Regex.run(~r/\(([^)]+)\)/, title(text)) do
      [_, range] -> range
      _ -> "historical"
    end
  end

  defp entry_range(%{from_unix: from_unix, to_unix: to_unix}),
    do: {:ok, from_unix, to_unix}

  defp entry_range(%{layer: :foundation}),
    do: {:error, "Foundation chapters do not expose raw message ranges."}

  defp render_foundation_layer([]), do: "  <layer name=\"foundation\" />"

  defp render_foundation_layer(entries) do
    """
      <layer name="foundation" resolution="chapter">
    #{Enum.map_join(entries, "\n", &render_entry/1)}
      </layer>
    """
    |> String.trim_trailing()
  end

  defp render_summary_layer(name, []) do
    "  <layer name=#{inspect(name)} />"
  end

  defp render_summary_layer(name, summaries) do
    entries = Enum.map(summaries, &summary_entry/1)

    """
      <layer name=#{inspect(name)}>
    #{Enum.map_join(entries, "\n", &render_entry/1)}
      </layer>
    """
    |> String.trim_trailing()
  end

  defp render_raw_tail(nil),
    do: "  <raw-tail state=\"unknown\" />"

  defp render_raw_tail(from_unix) do
    """
      <raw-tail from="#{format_datetime(from_unix)}" state="unfolding">
        Use action="messages" with from_date="#{format_datetime(from_unix)}"
        to inspect unsummarized primary evidence.
      </raw-tail>
    """
    |> String.trim_trailing()
  end

  defp render_entry(entry) do
    synopsis = excerpt(entry.text, [], 260)
    message_count = Map.get(entry, :message_count)

    count_attr =
      if is_integer(message_count),
        do: " messages=#{inspect(message_count)}",
        else: ""

    "    <interval ref=#{xml_attr(entry.ref)} range=#{xml_attr(entry.range)}#{count_attr} title=#{xml_attr(entry.title)}>#{xml_text(synopsis)}</interval>"
  end

  defp render_search_hit(entry, queries) do
    "  <hit ref=#{xml_attr(entry.ref)} layer=#{xml_attr(entry.layer)} range=#{xml_attr(entry.range)} title=#{xml_attr(entry.title)}>#{xml_text(excerpt(entry.text, queries, 420))}</hit>"
  end

  defp search_sort_key(entry) do
    layer_rank =
      case entry.layer do
        :volume -> 0
        :week -> 1
        :day -> 2
        :foundation -> 3
      end

    {layer_rank, -(Map.get(entry, :from_unix) || 0)}
  end

  defp latest_end([]), do: nil

  defp latest_end(summaries),
    do: summaries |> List.last() |> Map.fetch!(:to_date)

  defp after_boundary?(_summary, nil), do: true
  defp after_boundary?(summary, boundary), do: summary.from_date >= boundary

  defp ref_kind(%ChatSummary{metadata: %{"kind" => @volume_kind}}),
    do: "volume"

  defp ref_kind(%ChatSummary{metadata: %{"kind" => @weekly_kind}}),
    do: "week"

  defp ref_kind(%ChatSummary{}), do: "day"

  defp title(text) do
    first_line =
      text
      |> String.split("\n")
      |> Enum.find(&(String.trim(&1) != ""))

    case first_line do
      nil ->
        "Untitled"

      line ->
        line
        |> String.trim()
        |> String.trim_leading("#")
        |> String.trim()
        |> truncate(160)
    end
  end

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "…"
    else
      text
    end
  end

  defp excerpt(text, queries, max_length) do
    normalized = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    candidate =
      case Enum.filter(queries, &matches?(normalized, [&1])) do
        [] ->
          normalized

        matching ->
          alternatives =
            matching |> Enum.map(&Regex.escape/1) |> Enum.join("|")

          trailing =
            if max_length - 120 > 40, do: max_length - 120, else: 40

          case Regex.compile(
                 ".{0,120}(?:#{alternatives}).{0,#{trailing}}",
                 "isu"
               ) do
            {:ok, regex} ->
              case Regex.run(regex, normalized, capture: :first) do
                [match] -> match
                _ -> normalized
              end

            {:error, _reason} ->
              normalized
          end
      end

    if String.length(candidate) > max_length do
      String.slice(candidate, 0, max_length) <> "…"
    else
      candidate
    end
  end

  defp matches?(text, queries) do
    lower = String.downcase(text)
    Enum.any?(queries, &String.contains?(lower, String.downcase(&1)))
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp bounded_limit(value) do
    case parse_integer(value) do
      n when n > @max_search_limit -> @max_search_limit
      n when n > 0 -> n
      _ -> @default_search_limit
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_unix(datetime)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, datetime} ->
            datetime
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix()

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

  defp parse_to_datetime(value) do
    case {value, parse_datetime(value)} do
      {nil, _} ->
        nil

      {"", _} ->
        nil

      {date, unix} when is_binary(date) and is_integer(unix) ->
        if match?({:ok, _}, Date.from_iso8601(date)),
          do: unix + 86_400,
          else: unix

      _ ->
        nil
    end
  end

  defp format_range(from_unix, to_unix) do
    from_date = from_unix |> DateTime.from_unix!() |> DateTime.to_date()
    to_date = (to_unix - 1) |> DateTime.from_unix!() |> DateTime.to_date()

    if from_date == to_date do
      Date.to_iso8601(from_date)
    else
      "#{from_date}/#{to_date}"
    end
  end

  defp format_datetime(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

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
