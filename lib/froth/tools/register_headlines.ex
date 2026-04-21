defmodule Froth.Tools.RegisterHeadlines do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.ChatSummary
  alias Froth.Context.Block
  alias Froth.Event
  alias Froth.Repo
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.BotAdapter
  alias Froth.Telemetry.Span
  alias Froth.Tools.Support
  import Ecto.Query

  @impl true
  def name, do: "register_headlines"

  @impl true
  def label, do: "register headlines"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Submit the complete final set of headlines for one date after investigating the evidence. The headlines array must contain every item worth headlining for that date, not just one example.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "date" => %{
            "type" => "string",
            "description" => "The date being summarized, YYYY-MM-DD"
          },
          "headlines" => %{
            "type" => "array",
            "description" =>
              "The complete set of headlines worth keeping for this date. Include every worthy same-day headline in this array.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "emoji" => %{
                  "type" => "string",
                  "description" => "A single relevant emoji for the headline"
                },
                "title" => %{
                  "type" => "string",
                  "description" => "Short headline title"
                },
                "sentence" => %{
                  "type" => "string",
                  "description" => "One sentence expanding on the headline"
                },
                "from_time" => %{
                  "type" => "string",
                  "description" =>
                    "Approximate event start time, ISO 8601 UTC datetime string"
                },
                "to_time" => %{
                  "type" => "string",
                  "description" =>
                    "Approximate event end time, ISO 8601 UTC datetime string"
                }
              },
              "required" => [
                "emoji",
                "title",
                "sentence",
                "from_time",
                "to_time"
              ],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["date", "headlines"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(
        %Context{} = ctx,
        %ToolUse{input: %{"date" => date, "headlines" => headlines}},
        hooks
      )
      when is_binary(date) and is_list(headlines) do
    chat_id = Support.chat_id(ctx)
    session_id = Support.session_id(ctx)

    with {:ok, normalized_headlines} <- normalize_headlines(headlines) do
      case maybe_send_headlines_message(
             ctx,
             date,
             normalized_headlines,
             hooks
           ) do
        {:ok, _sent} ->
          store_headlines_registered_event(
            date,
            chat_id,
            normalized_headlines
          )

          Span.execute(
            [:froth, :headlines, :registered],
            nil,
            %{
              date: date,
              chat_id: chat_id,
              headlines: normalized_headlines,
              session_id: session_id
            },
            %{count: length(normalized_headlines)}
          )

          progress = headlines_progress(chat_id, date)

          {:ok,
           [
             Block.new(
               [
                 kind: "headlines_registered",
                 date: date,
                 count: length(normalized_headlines),
                 done_days: progress.done_days,
                 total_days: progress.total_days,
                 next_unfinished: progress.next_unfinished
               ],
               nil
             )
           ]}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  def execute(_ctx, _tool_call, _hooks),
    do: {:error, "register_headlines requires date and headlines"}

  defp maybe_send_headlines_message(
         %Context{} = ctx,
         date,
         normalized_headlines,
         hooks
       )
       when is_binary(date) and is_list(normalized_headlines) do
    if ctx.spam do
      chat_id = Support.chat_id(ctx)
      session_id = Support.session_id(ctx)
      {text, entities} = format_headlines_message(date, normalized_headlines)

      send_message_fun =
        Keyword.get(hooks, :send_message_fun, &BotAdapter.send_message/4)

      reply_markup = headlines_reply_markup(ctx)

      send_message_opts =
        [entities: entities]
        |> maybe_put_send_message_opt(:reply_markup, reply_markup)

      send_message_fun.(session_id, chat_id, text, send_message_opts)
    else
      {:ok, :suppressed}
    end
  end

  defp normalize_headlines(headlines) when is_list(headlines) do
    headlines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {headline, index}, {:ok, acc} ->
      case normalize_headline(headline) do
        {:ok, normalized} ->
          {:cont, {:ok, acc ++ [normalized]}}

        {:error, reason} ->
          {:halt, {:error, "headline #{index + 1}: #{reason}"}}
      end
    end)
  end

  defp normalize_headline(%{
         "emoji" => emoji,
         "title" => title,
         "sentence" => sentence,
         "from_time" => from_time,
         "to_time" => to_time
       })
       when is_binary(emoji) and is_binary(title) and is_binary(sentence) and
              is_binary(from_time) and is_binary(to_time) do
    normalize_headline_fields(emoji, title, sentence, from_time, to_time)
  end

  defp normalize_headline(%{
         emoji: emoji,
         title: title,
         sentence: sentence,
         from_time: from_time,
         to_time: to_time
       })
       when is_binary(emoji) and is_binary(title) and is_binary(sentence) and
              is_binary(from_time) and is_binary(to_time) do
    normalize_headline_fields(emoji, title, sentence, from_time, to_time)
  end

  defp normalize_headline(_headline),
    do:
      {:error,
       "expected emoji, title, sentence, from_time, and to_time strings"}

  defp format_headlines_message(date, headlines)
       when is_binary(date) and is_list(headlines) do
    separator = "\n\n"

    body =
      headlines
      |> Enum.map_join(separator, &headline_line/1)

    text =
      case body do
        "" -> date
        _ -> date <> "\n\n" <> body
      end

    header_entities = [bold_entity(0, utf16_length(date))]

    entities =
      headlines
      |> Enum.reduce(
        {header_entities, utf16_length(date <> separator)},
        fn headline, {acc, offset} ->
          title = headline["title"]
          line = headline_line(headline)
          title_offset = offset + headline_title_offset(headline)
          next_offset = offset + utf16_length(line) + utf16_length(separator)

          {acc ++ [bold_entity(title_offset, utf16_length(title))],
           next_offset}
        end
      )
      |> elem(0)

    {text, entities}
  end

  defp store_headlines_registered_event(date, chat_id, headlines)
       when is_binary(date) and is_integer(chat_id) and is_list(headlines) do
    %Event{}
    |> Event.changeset(%{
      event: "froth.headlines.registered",
      metadata: %{
        "date" => date,
        "chat_id" => Integer.to_string(chat_id),
        "headlines" => headlines
      },
      measurements: %{"count" => length(headlines)}
    })
    |> Repo.insert!(log: false)
  end

  defp normalize_headline_fields(emoji, title, sentence, from_time, to_time) do
    with {:ok, normalized_emoji} <- normalize_headline_emoji(emoji),
         {:ok, normalized_from_time, from_datetime} <-
           normalize_iso8601_datetime(from_time, "from_time"),
         {:ok, normalized_to_time, to_datetime} <-
           normalize_iso8601_datetime(to_time, "to_time"),
         :ok <- validate_headline_time_range(from_datetime, to_datetime) do
      {:ok,
       %{
         "emoji" => normalized_emoji,
         "title" => String.trim(title),
         "sentence" => String.trim(sentence),
         "from_time" => normalized_from_time,
         "to_time" => normalized_to_time
       }}
    end
  end

  defp normalize_headline_emoji(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "emoji must be a non-empty string"}

      length(String.graphemes(trimmed)) != 1 ->
        {:error, "emoji must be a single emoji"}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_iso8601_datetime(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, "#{field_name} must be a non-empty ISO 8601 datetime"}
    else
      case parse_iso8601_datetime(trimmed) do
        {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime), datetime}
        :error -> {:error, "#{field_name} must be an ISO 8601 datetime"}
      end
    end
  end

  defp parse_iso8601_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive_datetime} ->
            {:ok, DateTime.from_naive!(naive_datetime, "Etc/UTC")}

          {:error, _reason} ->
            :error
        end
    end
  end

  defp validate_headline_time_range(from_datetime, to_datetime)
       when is_struct(from_datetime, DateTime) and
              is_struct(to_datetime, DateTime) do
    case DateTime.compare(from_datetime, to_datetime) do
      :gt -> {:error, "from_time must be before or equal to to_time"}
      _ -> :ok
    end
  end

  defp headline_line(%{
         "emoji" => emoji,
         "title" => title,
         "from_time" => from_time,
         "to_time" => to_time
       }) do
    "#{emoji} #{title} #{headline_time_window(from_time, to_time)}"
  end

  defp headline_title_offset(%{"emoji" => emoji}) when is_binary(emoji),
    do: utf16_length("#{emoji} ")

  defp headline_time_window(from_time, to_time)
       when is_binary(from_time) and is_binary(to_time) do
    {:ok, from_datetime} = parse_iso8601_datetime(from_time)
    {:ok, to_datetime} = parse_iso8601_datetime(to_time)

    "(" <>
      Calendar.strftime(from_datetime, "%H:%M") <>
      "-" <> Calendar.strftime(to_datetime, "%H:%M") <> " UTC)"
  end

  defp utf16_length(text) when is_binary(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp headlines_progress(chat_id, current_date)
       when is_integer(chat_id) and is_binary(current_date) do
    summary_dates = available_summary_dates(chat_id)

    registered_dates =
      chat_id
      |> registered_headline_dates()
      |> Enum.reduce(MapSet.new(), &MapSet.put(&2, &1))
      |> MapSet.put(current_date)

    %{
      done_days: MapSet.size(registered_dates),
      total_days: length(summary_dates),
      next_unfinished:
        Enum.find(summary_dates, fn date ->
          not MapSet.member?(registered_dates, date)
        end)
    }
  end

  defp available_summary_dates(chat_id) when is_integer(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        distinct:
          fragment("timezone('UTC', to_timestamp(?))::date", s.from_date),
        order_by:
          fragment("timezone('UTC', to_timestamp(?))::date", s.from_date),
        select:
          fragment("timezone('UTC', to_timestamp(?))::date", s.from_date)
      ),
      log: false
    )
    |> Enum.map(&Date.to_iso8601/1)
  end

  defp registered_headline_dates(chat_id) when is_integer(chat_id) do
    chat_id_string = Integer.to_string(chat_id)

    Repo.all(
      from(e in Event,
        where:
          e.event == "froth.headlines.registered" and
            fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string),
        distinct: fragment("?->>'date'", e.metadata),
        order_by: fragment("?->>'date'", e.metadata),
        select: fragment("?->>'date'", e.metadata)
      ),
      log: false
    )
  end

  defp maybe_put_send_message_opt(keyword, _key, nil), do: keyword

  defp maybe_put_send_message_opt(keyword, key, value),
    do: Keyword.put(keyword, key, value)

  defp headlines_reply_markup(%Context{
         cycle_id: cycle_id,
         bot_config: %BotConfig{id: bot_id, bot_username: bot_username}
       })
       when is_binary(cycle_id) and cycle_id != "" and is_binary(bot_id) and
              bot_id != "" and
              is_binary(bot_username) and bot_username != "" do
    %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => [
        [
          %{
            "@type" => "inlineKeyboardButton",
            "text" => "Open",
            "type" => %{
              "@type" => "inlineKeyboardButtonTypeUrl",
              "url" =>
                "https://t.me/#{bot_username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
            }
          }
        ]
      ]
    }
  end

  defp headlines_reply_markup(_ctx), do: nil

  defp bold_entity(offset, length)
       when is_integer(offset) and is_integer(length) do
    %{
      "@type" => "textEntity",
      "offset" => offset,
      "length" => length,
      "type" => %{"@type" => "textEntityTypeBold"}
    }
  end
end
