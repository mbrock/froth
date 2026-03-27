defmodule Froth.DailyDigest do
  @moduledoc """
  Scheduled UTC daily digest delivery for the main group chat.

  On full nodes, this process wakes shortly after midnight UTC, backfills any
  missing daily summaries, generates missing headlines when needed, and sends
  Charlie's digest as a single Telegram document message with the headlines in
  the caption and the full summary attached as HTML.

  You can also run the same pipeline manually:

      Froth.DailyDigest.run_now()
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Froth.{ChatSummary, Event, Headlines, Repo, Summarizer, Telegram}

  @default_chat_id -1_003_690_254_489
  @default_session_id "charlie"
  @default_run_at_utc ~T[00:05:00]
  @default_startup_delay_ms 15_000
  @default_digest_dir Path.expand("tmp/daily-digests")
  @scheduled_tick :run_scheduled_digest
  @startup_tick :run_startup_digest
  @daily_seconds 86_400

  defstruct [
    :chat_id,
    :session_id,
    :run_at_utc,
    :startup_delay_ms,
    :digest_dir,
    :headline_model,
    :timer_ref,
    :next_run_at,
    :task_ref,
    :task_pid
  ]

  @type run_result :: %{
          pending_dates: [Date.t()],
          summarized_dates: [Date.t()],
          no_message_dates: [Date.t()],
          sent_dates: [Date.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec run_now(keyword()) :: {:ok, run_result()} | {:error, term()}
  def run_now(opts \\ []) when is_list(opts) do
    opts = runtime_opts(opts)
    today = Keyword.get(opts, :today, Date.utc_today())
    chat_id = resolve_chat_id(opts)
    session_id = resolve_session_id(opts)

    pending_summary_dates_fun =
      Keyword.get(opts, :pending_summary_dates_fun, &Summarizer.pending_summary_dates/2)

    summarize_day_fun = Keyword.get(opts, :summarize_day_fun, &Summarizer.summarize_day/2)

    extract_headlines_fun =
      Keyword.get(opts, :extract_headlines_fun, fn digest_chat_id, extract_opts ->
        Headlines.extract(Keyword.merge([chat_id: digest_chat_id], extract_opts))
      end)

    send_document_fun = Keyword.get(opts, :send_document_fun, &Telegram.send_document/4)

    pending_dates = pending_summary_dates_fun.(chat_id, today)

    with {:ok, %{summarized_dates: summarized_dates, no_message_dates: no_message_dates}} <-
           summarize_pending_dates(chat_id, pending_dates, summarize_day_fun),
         sendable_summaries <- unsent_daily_summaries(chat_id, today),
         :ok <-
           maybe_generate_missing_headlines(
             sendable_summaries,
             chat_id,
             opts,
             extract_headlines_fun
           ),
         {:ok, sent_dates} <-
           send_digests(
             sendable_summaries,
             chat_id,
             session_id,
             opts,
             send_document_fun
           ) do
      {:ok,
       %{
         pending_dates: pending_dates,
         summarized_dates: summarized_dates,
         no_message_dates: no_message_dates,
         sent_dates: sent_dates
       }}
    end
  end

  @impl true
  def init(opts) do
    opts = runtime_opts(opts)

    if enabled?(opts) do
      state =
        %__MODULE__{
          chat_id: resolve_chat_id(opts),
          session_id: resolve_session_id(opts),
          run_at_utc: resolve_run_at_utc(opts),
          startup_delay_ms: resolve_startup_delay_ms(opts),
          digest_dir: resolve_digest_dir(opts),
          headline_model: resolve_headline_model(opts)
        }
        |> schedule_startup_tick()
        |> schedule_next_run()

      Logger.info(
        "DailyDigest started for chat #{state.chat_id}; next run at " <>
          "#{DateTime.to_iso8601(state.next_run_at)} (UTC)"
      )

      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(@startup_tick, state) do
    {:noreply, maybe_start_run(state, :startup)}
  end

  def handle_info(@scheduled_tick, state) do
    state = schedule_next_run(%{state | timer_ref: nil})
    {:noreply, maybe_start_run(state, :scheduled)}
  end

  def handle_info({ref, {:ok, result}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log_run_result(state, result)
    {:noreply, %{state | task_ref: nil, task_pid: nil}}
  end

  def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    Logger.error("DailyDigest failed: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil, task_pid: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("DailyDigest worker exited: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil, task_pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_start_run(%{task_ref: ref} = state, _reason) when is_reference(ref) do
    Logger.warning("DailyDigest skipped because a previous run is still in flight.")
    state
  end

  defp maybe_start_run(state, reason) do
    Logger.info("DailyDigest starting #{reason} run for chat #{state.chat_id}.")

    task =
      Task.Supervisor.async_nolink(Froth.TaskSupervisor, fn ->
        run_now(
          chat_id: state.chat_id,
          session_id: state.session_id,
          run_at_utc: state.run_at_utc,
          digest_dir: state.digest_dir,
          headline_model: state.headline_model
        )
      end)

    %{state | task_ref: task.ref, task_pid: task.pid}
  end

  defp summarize_pending_dates(_chat_id, [], _summarize_day_fun) do
    {:ok, %{summarized_dates: [], no_message_dates: []}}
  end

  defp summarize_pending_dates(chat_id, pending_dates, summarize_day_fun)
       when is_integer(chat_id) and is_list(pending_dates) and is_function(summarize_day_fun, 2) do
    Enum.reduce_while(
      pending_dates,
      {:ok, %{summarized_dates: [], no_message_dates: []}},
      fn date, {:ok, acc} ->
        case summarize_day_fun.(chat_id, date) do
          {:ok, _summary} ->
            {:cont, {:ok, %{acc | summarized_dates: acc.summarized_dates ++ [date]}}}

          {:error, :no_messages} ->
            {:cont, {:ok, %{acc | no_message_dates: acc.no_message_dates ++ [date]}}}

          {:error, reason} ->
            {:halt, {:error, {:summarize_failed, date, reason}}}
        end
      end
    )
  end

  defp unsent_daily_summaries(chat_id, today)
       when is_integer(chat_id) and is_struct(today, Date) do
    cutoff_date = Date.add(today, -1)

    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        order_by: [asc: s.from_date, desc: s.inserted_at]
      ),
      log: false
    )
    |> Enum.filter(&daily_summary?/1)
    |> Enum.group_by(&summary_date(&1))
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map(fn {date, [summary | _]} -> {date, summary} end)
    |> Enum.filter(fn {date, _summary} ->
      Date.compare(date, cutoff_date) != :gt and not digest_sent?(chat_id, date)
    end)
  end

  defp maybe_generate_missing_headlines([], _chat_id, _opts, _extract_headlines_fun), do: :ok

  defp maybe_generate_missing_headlines(sendable_summaries, chat_id, opts, extract_headlines_fun)
       when is_list(sendable_summaries) and is_integer(chat_id) and is_list(opts) and
              is_function(extract_headlines_fun, 2) do
    missing_dates =
      sendable_summaries
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(fn date ->
        match?(:missing, registered_headlines_for_date(chat_id, date))
      end)

    if missing_dates == [] do
      :ok
    else
      extract_opts =
        [spam: false]
        |> maybe_put_extract_opt(:model, resolve_headline_model(opts))

      _ = extract_headlines_fun.(chat_id, extract_opts)
      :ok
    end
  end

  defp send_digests([], _chat_id, _session_id, _opts, _send_document_fun), do: {:ok, []}

  defp send_digests(sendable_summaries, chat_id, session_id, opts, send_document_fun)
       when is_list(sendable_summaries) and is_integer(chat_id) and is_binary(session_id) and
              is_list(opts) and is_function(send_document_fun, 4) do
    Enum.reduce_while(sendable_summaries, {:ok, []}, fn {date, summary}, {:ok, sent_dates} ->
      case registered_headlines_for_date(chat_id, date) do
        {:ok, headlines} ->
          with {:ok, path} <- write_summary_file(summary, date, opts),
               {caption, entities} <- format_digest_caption(date, headlines),
               {:ok, sent_message} <-
                 send_document_fun.(session_id, chat_id, path,
                   caption: caption,
                   caption_entities: entities
                 ),
               {:ok, _event} <-
                 store_digest_sent_event(chat_id, date, summary, sent_message, headlines) do
            {:cont, {:ok, sent_dates ++ [date]}}
          else
            {:error, reason} ->
              {:halt, {:error, {:send_failed, date, reason}}}
          end

        :missing ->
          {:halt, {:error, {:missing_headlines, date}}}
      end
    end)
  end

  defp registered_headlines_for_date(chat_id, %Date{} = date) when is_integer(chat_id) do
    date_str = Date.to_iso8601(date)
    chat_id_string = Integer.to_string(chat_id)

    Repo.one(
      from(e in Event,
        where:
          e.event == "froth.headlines.registered" and
            fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string) and
            fragment("?->>'date' = ?", e.metadata, ^date_str),
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.metadata
      ),
      log: false
    )
    |> case do
      %{"headlines" => headlines} when is_list(headlines) -> {:ok, headlines}
      %{} -> {:ok, []}
      nil -> :missing
    end
  end

  defp digest_sent?(chat_id, %Date{} = date) when is_integer(chat_id) do
    date_str = Date.to_iso8601(date)
    chat_id_string = Integer.to_string(chat_id)

    Repo.exists?(
      from(e in Event,
        where:
          e.event == "froth.daily_digest.sent" and
            fragment("?->>'chat_id' = ?", e.metadata, ^chat_id_string) and
            fragment("?->>'date' = ?", e.metadata, ^date_str),
        select: 1
      ),
      log: false
    )
  end

  defp store_digest_sent_event(
         chat_id,
         %Date{} = date,
         %ChatSummary{} = summary,
         sent_message,
         headlines
       )
       when is_integer(chat_id) and is_list(headlines) do
    metadata =
      %{
        "chat_id" => Integer.to_string(chat_id),
        "date" => Date.to_iso8601(date),
        "summary_id" => summary.id,
        "headline_count" => length(headlines)
      }
      |> maybe_put_message_id(sent_message)

    %Event{}
    |> Event.changeset(%{
      event: "froth.daily_digest.sent",
      metadata: metadata,
      measurements: %{
        "headline_count" => length(headlines),
        "message_count" => summary.message_count || 0
      }
    })
    |> Repo.insert()
  end

  defp maybe_put_message_id(metadata, %{"id" => message_id}) when is_integer(message_id) do
    Map.put(metadata, "message_id", message_id)
  end

  defp maybe_put_message_id(metadata, _sent_message), do: metadata

  defp write_summary_file(%ChatSummary{} = summary, %Date{} = date, opts) when is_list(opts) do
    digest_dir = resolve_digest_dir(opts)
    path = Path.join(digest_dir, "chat-#{summary.chat_id}-#{Date.to_iso8601(date)}.html")

    with :ok <- File.mkdir_p(digest_dir),
         :ok <- File.write(path, render_summary_html(summary, date)) do
      {:ok, path}
    end
  end

  defp render_summary_html(%ChatSummary{} = summary, %Date{} = date) do
    formatted_date = Calendar.strftime(date, "%A, %B %-d, %Y")

    paragraphs =
      summary.summary_text
      |> String.split(~r/\n\n+/, trim: true)
      |> Enum.map_join("\n", fn paragraph ->
        paragraph =
          paragraph
          |> String.replace("\n", " ")
          |> html_escape()

        "<p>#{paragraph}</p>"
      end)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Froth Daily Summary - #{html_escape(Date.to_iso8601(date))}</title>
      <style>
        body {
          margin: 0;
          background: #f4efe4;
          color: #181512;
          font-family: Georgia, "Times New Roman", serif;
        }
        main {
          max-width: 780px;
          margin: 0 auto;
          padding: 48px 24px 72px;
        }
        .kicker {
          letter-spacing: 0.18em;
          text-transform: uppercase;
          font: 700 12px/1.4 Arial, Helvetica, sans-serif;
          color: #8a4a17;
          margin: 0 0 16px;
        }
        h1 {
          margin: 0;
          font-size: clamp(2.2rem, 6vw, 4.4rem);
          line-height: 0.94;
          font-weight: 600;
        }
        .meta {
          margin: 18px 0 32px;
          color: #6d655d;
          font: 600 13px/1.4 Arial, Helvetica, sans-serif;
          letter-spacing: 0.08em;
          text-transform: uppercase;
        }
        article {
          background: rgba(255, 255, 255, 0.78);
          border: 1px solid rgba(24, 21, 18, 0.14);
          box-shadow: 0 24px 80px rgba(24, 21, 18, 0.08);
          padding: 28px 26px;
        }
        p {
          margin: 0 0 1.1em;
          font-size: 20px;
          line-height: 1.75;
          text-wrap: pretty;
        }
        p:last-child {
          margin-bottom: 0;
        }
        footer {
          margin-top: 28px;
          color: #6d655d;
          font: 500 13px/1.5 Arial, Helvetica, sans-serif;
        }
        @media (max-width: 640px) {
          main {
            padding: 28px 16px 48px;
          }
          article {
            padding: 20px 18px;
          }
          p {
            font-size: 18px;
          }
        }
      </style>
    </head>
    <body>
      <main>
        <p class="kicker">Charlie Daily Digest</p>
        <h1>#{html_escape(formatted_date)}</h1>
        <p class="meta">#{summary.message_count || 0} messages summarized in UTC</p>
        <article>
          #{paragraphs}
        </article>
        <footer>
          Generated by Charlie (@charliebuddybot) from the Froth daily summary pipeline.
        </footer>
      </main>
    </body>
    </html>
    """
  end

  defp format_digest_caption(%Date{} = date, headlines) when is_list(headlines) do
    {headline_text, headline_entities} = format_headlines_caption(date, headlines)

    attachment_note = "\n\nSummary attached as HTML."
    {headline_text <> attachment_note, headline_entities}
  end

  defp format_headlines_caption(%Date{} = date, headlines) when is_list(headlines) do
    date_text = Date.to_iso8601(date)
    separator = "\n\n"

    body =
      headlines
      |> Enum.map_join(separator, &headline_line/1)

    text =
      case body do
        "" -> date_text
        _ -> date_text <> separator <> body
      end

    header_entities = [bold_entity(0, utf16_length(date_text))]

    entities =
      headlines
      |> Enum.reduce({header_entities, utf16_length(date_text <> separator)}, fn headline,
                                                                                 {acc, offset} ->
        title = Map.get(headline, "title") || Map.get(headline, :title) || ""
        line = headline_line(headline)
        title_offset = offset + headline_title_offset(headline)
        next_offset = offset + utf16_length(line) + utf16_length(separator)
        {acc ++ [bold_entity(title_offset, utf16_length(title))], next_offset}
      end)
      |> elem(0)

    {text, entities}
  end

  defp headline_line(%{
         "emoji" => emoji,
         "title" => title,
         "from_time" => from_time,
         "to_time" => to_time
       }) do
    "#{emoji} #{title} #{headline_time_window(from_time, to_time)}"
  end

  defp headline_line(%{
         emoji: emoji,
         title: title,
         from_time: from_time,
         to_time: to_time
       }) do
    headline_line(%{
      "emoji" => emoji,
      "title" => title,
      "from_time" => from_time,
      "to_time" => to_time
    })
  end

  defp headline_line(%{"emoji" => emoji, "title" => title})
       when is_binary(emoji) and is_binary(title),
       do: "#{emoji} #{title}"

  defp headline_line(%{emoji: emoji, title: title}) when is_binary(emoji) and is_binary(title),
    do: "#{emoji} #{title}"

  defp headline_line(_headline), do: "Headline"

  defp headline_title_offset(%{"emoji" => emoji}) when is_binary(emoji),
    do: utf16_length("#{emoji} ")

  defp headline_title_offset(%{emoji: emoji}) when is_binary(emoji), do: utf16_length("#{emoji} ")
  defp headline_title_offset(_headline), do: 0

  defp headline_time_window(from_time, to_time)
       when is_binary(from_time) and is_binary(to_time) do
    with {:ok, from_datetime} <- parse_iso8601_datetime(from_time),
         {:ok, to_datetime} <- parse_iso8601_datetime(to_time) do
      "(" <>
        Calendar.strftime(from_datetime, "%H:%M") <>
        "-" <> Calendar.strftime(to_datetime, "%H:%M") <> " UTC)"
    else
      _ -> ""
    end
  end

  defp headline_time_window(_from_time, _to_time), do: ""

  defp parse_iso8601_datetime(value) when is_binary(value) do
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

  defp bold_entity(offset, length) when is_integer(offset) and is_integer(length) do
    %{
      "@type" => "textEntity",
      "offset" => offset,
      "length" => length,
      "type" => %{"@type" => "textEntityTypeBold"}
    }
  end

  defp utf16_length(text) when is_binary(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp daily_summary?(%ChatSummary{from_date: from_unix, to_date: to_unix})
       when is_integer(from_unix) and is_integer(to_unix) do
    from_unix != to_unix and to_unix - from_unix <= @daily_seconds
  end

  defp daily_summary?(_summary), do: false

  defp summary_date(%ChatSummary{from_date: from_unix}) when is_integer(from_unix) do
    DateTime.from_unix!(from_unix, :second)
    |> DateTime.to_date()
  end

  defp schedule_startup_tick(%__MODULE__{startup_delay_ms: startup_delay_ms} = state)
       when is_integer(startup_delay_ms) and startup_delay_ms >= 0 do
    Process.send_after(self(), @startup_tick, startup_delay_ms)
    state
  end

  defp schedule_next_run(%__MODULE__{run_at_utc: run_at_utc, timer_ref: timer_ref} = state)
       when is_struct(run_at_utc, Time) do
    if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)

    now = DateTime.utc_now()
    next_run_at = next_run_at(now, run_at_utc)
    delay_ms = max(DateTime.diff(next_run_at, now, :millisecond), 0)
    ref = Process.send_after(self(), @scheduled_tick, delay_ms)

    %{state | timer_ref: ref, next_run_at: next_run_at}
  end

  @spec next_run_at(DateTime.t(), Time.t()) :: DateTime.t()
  def next_run_at(%DateTime{} = now, %Time{} = run_at_utc) do
    today = DateTime.to_date(now)
    today_run = DateTime.new!(today, run_at_utc, "Etc/UTC")

    case DateTime.compare(today_run, now) do
      :gt -> today_run
      _ -> DateTime.new!(Date.add(today, 1), run_at_utc, "Etc/UTC")
    end
  end

  defp log_run_result(state, result) when is_map(result) do
    Logger.info(
      "DailyDigest completed for chat #{state.chat_id}: " <>
        "#{length(result.summarized_dates)} summarized, " <>
        "#{length(result.no_message_dates)} empty, " <>
        "#{length(result.sent_dates)} sent."
    )
  end

  defp runtime_opts(opts) when is_list(opts) do
    Keyword.merge(Application.get_env(:froth, __MODULE__, []), opts)
  end

  defp enabled?(opts) when is_list(opts) do
    opts
    |> Keyword.get(:enabled, true)
    |> normalize_boolean(true)
  end

  defp resolve_chat_id(opts) when is_list(opts) do
    opts
    |> Keyword.get(:chat_id, @default_chat_id)
    |> normalize_integer(@default_chat_id)
  end

  defp resolve_session_id(opts) when is_list(opts) do
    opts
    |> Keyword.get(:session_id, @default_session_id)
    |> to_string()
  end

  defp resolve_run_at_utc(opts) when is_list(opts) do
    case Keyword.get(opts, :run_at_utc, @default_run_at_utc) do
      %Time{} = time ->
        time

      value when is_binary(value) ->
        case Time.from_iso8601(String.trim(value)) do
          {:ok, time} -> time
          {:error, _reason} -> @default_run_at_utc
        end

      _ ->
        @default_run_at_utc
    end
  end

  defp resolve_startup_delay_ms(opts) when is_list(opts) do
    opts
    |> Keyword.get(:startup_delay_ms, @default_startup_delay_ms)
    |> normalize_integer(@default_startup_delay_ms)
  end

  defp resolve_digest_dir(opts) when is_list(opts) do
    opts
    |> Keyword.get(:digest_dir, @default_digest_dir)
    |> to_string()
    |> Path.expand()
  end

  defp resolve_headline_model(opts) when is_list(opts) do
    case Keyword.get(opts, :headline_model) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          model -> model
        end

      _ ->
        nil
    end
  end

  defp maybe_put_extract_opt(opts, _key, nil), do: opts
  defp maybe_put_extract_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp normalize_boolean(value, _default) when is_boolean(value), do: value

  defp normalize_boolean(value, default) when is_binary(value) do
    case String.trim(value) |> String.downcase() do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> default
    end
  end

  defp normalize_boolean(_value, default), do: default

  defp html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
