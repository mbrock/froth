defmodule Froth.HeadlinesLedger do
  @moduledoc """
  Loads the saved headlines register for the server-rendered headlines page.
  """

  import Ecto.Query

  alias Froth.{ChatSummary, Event, Repo}

  def build(params \\ %{}) when is_map(params) do
    available_chat_ids = available_chat_ids()
    chat_id = selected_chat_id(Map.get(params, "chat_id"), available_chat_ids)
    headline_days = list_headline_days(chat_id)

    %{
      available_chat_ids: available_chat_ids,
      chat_id: chat_id,
      coverage: coverage(chat_id, headline_days),
      headline_days: headline_days,
      month_sections: month_sections(headline_days)
    }
  end

  defp available_chat_ids do
    summary_chat_ids =
      Repo.all(
        from(s in ChatSummary,
          distinct: s.chat_id,
          select: s.chat_id
        ),
        log: false
      )

    event_chat_ids =
      Repo.all(
        from(e in Event,
          where: e.event == "froth.headlines.registered",
          distinct: fragment("?->>'chat_id'", e.metadata),
          select: fragment("?->>'chat_id'", e.metadata)
        ),
        log: false
      )
      |> Enum.flat_map(&parse_chat_id/1)

    summary_chat_ids
    |> Kernel.++(event_chat_ids)
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  defp list_headline_days(nil), do: []

  defp list_headline_days(chat_id) when is_integer(chat_id) do
    chat_id_string = Integer.to_string(chat_id)

    Repo.all(
      from(e in Event,
        where:
          e.event == "froth.headlines.registered" and
            fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string),
        order_by: [desc: fragment("?->>'date'", e.metadata), desc: e.inserted_at],
        select: %{inserted_at: e.inserted_at, metadata: e.metadata}
      ),
      log: false
    )
    |> Enum.reduce({MapSet.new(), []}, fn %{inserted_at: inserted_at, metadata: metadata},
                                          {seen_dates, acc} ->
      case headline_day(metadata, inserted_at) do
        nil ->
          {seen_dates, acc}

        %{iso_date: iso_date} = day ->
          if MapSet.member?(seen_dates, iso_date) do
            {seen_dates, acc}
          else
            {MapSet.put(seen_dates, iso_date), [day | acc]}
          end
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.sort_by(& &1.date, {:desc, Date})
  end

  defp coverage(nil, headline_days), do: coverage_from_summary_dates([], headline_days)

  defp coverage(chat_id, headline_days) when is_integer(chat_id) do
    summary_dates =
      Repo.all(
        from(s in ChatSummary,
          where: s.chat_id == ^chat_id,
          distinct: fragment("timezone('UTC', to_timestamp(?))::date", s.from_date),
          order_by: fragment("timezone('UTC', to_timestamp(?))::date", s.from_date),
          select: fragment("timezone('UTC', to_timestamp(?))::date", s.from_date)
        ),
        log: false
      )
      |> Enum.map(&Date.to_iso8601/1)

    coverage_from_summary_dates(summary_dates, headline_days)
  end

  defp coverage_from_summary_dates(summary_dates, headline_days) do
    filed_dates = MapSet.new(Enum.map(headline_days, & &1.iso_date))
    missing_dates = Enum.reject(summary_dates, &MapSet.member?(filed_dates, &1))

    %{
      total_days: length(summary_dates),
      filed_days: length(headline_days),
      total_headlines: Enum.reduce(headline_days, 0, &(&1.headline_count + &2)),
      missing_count: length(missing_dates),
      missing_dates: missing_dates,
      first_day: List.last(summary_dates) || maybe_day_iso(List.last(headline_days)),
      last_day: List.first(summary_dates) || maybe_day_iso(List.first(headline_days))
    }
  end

  defp month_sections(headline_days) do
    headline_days
    |> Enum.reduce([], fn day, acc ->
      section_id = month_section_id(day.date)
      section_label = Calendar.strftime(day.date, "%B %Y")

      case acc do
        [%{id: ^section_id} = section | rest] ->
          [
            %{
              section
              | days: section.days ++ [day],
                day_count: section.day_count + 1,
                headline_count: section.headline_count + day.headline_count
            }
            | rest
          ]

        _ ->
          [
            %{
              id: section_id,
              label: section_label,
              days: [day],
              day_count: 1,
              headline_count: day.headline_count
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  defp headline_day(%{"date" => iso_date, "headlines" => headlines}, inserted_at)
       when is_binary(iso_date) and is_list(headlines) do
    with {:ok, date} <- Date.from_iso8601(iso_date) do
      normalized_headlines = Enum.map(headlines, &normalize_headline/1)

      %{
        date: date,
        iso_date: iso_date,
        weekday: Calendar.strftime(date, "%a"),
        inserted_at: inserted_at,
        headline_count: length(normalized_headlines),
        headlines: normalized_headlines
      }
    else
      _ -> nil
    end
  end

  defp headline_day(_metadata, _inserted_at), do: nil

  defp normalize_headline(headline) when is_map(headline) do
    emoji = string_field(headline, "emoji", :emoji, "■")
    title = string_field(headline, "title", :title, "Untitled")
    sentence = string_field(headline, "sentence", :sentence, "")
    from_time = string_field(headline, "from_time", :from_time)
    to_time = string_field(headline, "to_time", :to_time)

    %{
      emoji: emoji,
      title: title,
      sentence: sentence,
      from_time: from_time,
      to_time: to_time,
      time_window: time_window(from_time, to_time)
    }
  end

  defp selected_chat_id(param, available_chat_ids) do
    case parse_chat_id(param) do
      [chat_id] ->
        if chat_id in available_chat_ids do
          chat_id
        else
          List.first(available_chat_ids)
        end

      _ ->
        List.first(available_chat_ids)
    end
  end

  defp parse_chat_id(nil), do: []

  defp parse_chat_id(value) when is_integer(value), do: [value]

  defp parse_chat_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {chat_id, ""} -> [chat_id]
      _ -> []
    end
  end

  defp parse_chat_id(_value), do: []

  defp string_field(map, string_key, atom_key, default \\ nil) when is_map(map) do
    case Map.get(map, string_key) || Map.get(map, atom_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          text -> text
        end

      _ ->
        default
    end
  end

  defp time_window(from_time, to_time) when is_binary(from_time) and is_binary(to_time) do
    with {:ok, from_dt} <- parse_datetime(from_time),
         {:ok, to_dt} <- parse_datetime(to_time) do
      Calendar.strftime(from_dt, "%H:%M") <> "-" <> Calendar.strftime(to_dt, "%H:%M UTC")
    else
      _ -> nil
    end
  end

  defp time_window(_from_time, _to_time), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive_datetime} -> {:ok, DateTime.from_naive!(naive_datetime, "Etc/UTC")}
          {:error, _reason} -> :error
        end
    end
  end

  defp month_section_id(%Date{} = date), do: "month-" <> Calendar.strftime(date, "%Y-%m")

  defp maybe_day_iso(%{iso_date: iso_date}) when is_binary(iso_date), do: iso_date
  defp maybe_day_iso(_day), do: nil
end
