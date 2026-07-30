defmodule Froth.WeeklySummarizer do
  @moduledoc """
  Builds durable weekly chronicle chapters from stored daily chat summaries.

  The initial range bridges the hand-written chronicle, which ends on
  2026-03-23. Subsequent ranges are ordinary Monday-through-Sunday UTC weeks.
  """

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.{Config, Message}
  alias Froth.{ChatSummary, NarrativeContext, Repo}

  @model "claude-opus-5"
  @max_tokens 65_536
  @kind "weekly_chronicle"
  @default_start_date ~D[2026-03-24]

  @system_prompt """
  You are continuing The Chronicle, the standing narrative memory of a strange extended
  family of humans and software agents living together through a Telegram group chat.

  The supplied existing chapters establish the form, voice, scale, cast, and standard of
  selection. Continue that same document. Write from the same close, confident narrative
  position, occasionally using "we" when the chronicle does. Do not explain the premise to
  an outside audience and do not call anyone fictional.

  Build the chapter around a small number of load-bearing stories rather than listing every
  day or event. Open on a concrete scene or decisive sentence. Preserve exact names, numbers,
  commands, artifacts, errors, quotations, and absurd details when they make the story true.
  Treat technical architecture and failure as part of the characters' lives. Preserve
  philosophical arguments at the level of their actual ideas rather than labeling them
  vaguely. Notice when an incident becomes a concept, protocol, running joke, diagnosis, or
  principle the family may invoke later. Carry forward relevant older threads and say when
  the week resolves, reverses, or repeats them.

  Move naturally between comedy, engineering, intimacy, danger, money, politics, and theory
  without announcing category changes. Allow sharp short paragraphs when an event earns one.
  Prefer one exact quotation over a generic description. Do not manufacture causality,
  interior states, quotations, or connective tissue absent from the summaries. Do not polish
  away uncertainty or contradiction.

  End with a compressed coda: a return to the opening image, a structural irony, or a litany
  of what survived and what changed. Aim for roughly 1,200 to 2,500 words when the material
  supports it. No bullet points, no preamble, and no meta-commentary.
  """

  def kind, do: @kind

  def summarize_range(chat_id, %Date{} = from_date, %Date{} = to_date)
      when is_integer(chat_id) do
    daily = daily_summaries(chat_id, from_date, to_date)

    if daily == [] do
      {:error, :no_summaries}
    else
      before_unix = day_start(from_date)
      prior = NarrativeContext.for_weekly_summary(chat_id, before_unix)

      chapter_number =
        8 + NarrativeContext.weekly_chapter_count(chat_id, before_unix)

      prompt =
        build_prompt(
          from_date,
          to_date,
          daily,
          prior,
          chapter_number,
          manual_chronicle()
        )

      config = %Config{
        system: @system_prompt,
        model: @model,
        max_tokens: @max_tokens,
        tools: []
      }

      user_msg = Message.user(prompt)

      {cycle, stream} = Agent.run(user_msg, config)

      text =
        Enum.reduce(stream, nil, fn
          {:stream, {:text_delta, delta}}, acc ->
            IO.write(delta)
            acc

          {:stream, {:thinking_delta, %{"delta" => thinking}}}, acc ->
            IO.write([IO.ANSI.faint(), thinking, IO.ANSI.reset()])
            acc

          {:stream, {:thinking_stop, _}}, acc ->
            IO.write("\n---\n")
            acc

          {:message, %{role: :agent} = msg}, _ ->
            Message.extract_text(msg.content)

          _, acc ->
            acc
        end)

      IO.write("\n")

      if is_binary(text) and String.trim(text) != "" do
        save(chat_id, from_date, to_date, text, daily, cycle.id)
      else
        {:error, :no_response}
      end
    end
  end

  def pending_ranges(chat_id, today \\ Date.utc_today(), opts \\ []) do
    start_date = Keyword.get(opts, :start_date, @default_start_date)

    yesterday = Date.add(today, -1)

    last_complete_sunday =
      Date.add(yesterday, -rem(Date.day_of_week(yesterday), 7))

    next_date =
      case latest_weekly_end(chat_id) do
        nil -> start_date
        date -> Date.add(date, 1)
      end

    build_ranges(next_date, last_complete_sunday, [])
  end

  def list(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        where: fragment("?->>'kind' = ?", s.metadata, @kind),
        order_by: [asc: s.from_date]
      )
    )
  end

  defp build_ranges(from_date, last_sunday, acc) do
    if Date.compare(from_date, last_sunday) == :gt do
      Enum.reverse(acc)
    else
      days_to_sunday = 7 - Date.day_of_week(from_date)
      to_date = min_date(Date.add(from_date, days_to_sunday), last_sunday)

      build_ranges(Date.add(to_date, 1), last_sunday, [
        {from_date, to_date} | acc
      ])
    end
  end

  defp min_date(left, right) do
    if Date.compare(left, right) == :gt, do: right, else: left
  end

  defp latest_weekly_end(chat_id) do
    Repo.one(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        where: fragment("?->>'kind' = ?", s.metadata, @kind),
        order_by: [desc: s.to_date],
        limit: 1,
        select: s.to_date
      ),
      log: false
    )
    |> case do
      nil ->
        nil

      unix ->
        unix |> DateTime.from_unix!() |> DateTime.to_date() |> Date.add(-1)
    end
  end

  defp daily_summaries(chat_id, from_date, to_date) do
    from_unix = day_start(from_date)
    to_unix = day_start(Date.add(to_date, 1))

    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        where: s.from_date >= ^from_unix and s.from_date < ^to_unix,
        where: s.from_date != s.to_date and s.to_date - s.from_date <= 86_400,
        order_by: [asc: s.from_date, desc: s.inserted_at]
      ),
      log: false
    )
    |> Enum.group_by(& &1.from_date)
    |> Enum.map(fn {_date, rows} ->
      Enum.max_by(rows, &String.length(&1.summary_text))
    end)
    |> Enum.sort_by(& &1.from_date)
  end

  defp build_prompt(
         from_date,
         to_date,
         daily,
         prior,
         chapter_number,
         foundation
       ) do
    prior_text =
      Enum.map_join(prior, "\n\n", fn summary ->
        "--- #{date(summary.from_date)} to #{Date.add(date(summary.to_date), -1)} ---\n#{summary.summary_text}"
      end)

    daily_text =
      Enum.map_join(daily, "\n\n", fn summary ->
        "--- #{date(summary.from_date)} ---\n#{summary.summary_text}"
      end)

    continuity =
      if Enum.any?(prior, &NarrativeContext.volume?/1) do
        """
        CLOSED NARRATIVE CONTEXT AT THE RIGHT RESOLUTION:

        #{prior_text}
        """
      else
        """
        EXISTING HAND-WRITTEN CHRONICLE — AUTHORITATIVE CONTINUITY AND STYLE:

        #{foundation}

        #{if prior_text == "", do: "", else: "AUTOMATIC CHAPTERS WRITTEN SINCE THE HAND-WRITTEN FOUNDATION:\n\n#{prior_text}"}
        """
      end

    """
    #{continuity}

    Write Chapter #{chapter_number}, covering #{from_date} through #{to_date}.
    Begin exactly with a Markdown H1 in this form, choosing a short thematic title:

    # Chapter #{chapter_number}: The Title (#{from_date}–#{to_date})

    Then write the chapter itself. Do not repeat or summarize the earlier chapters merely
    because they appear above; use them to understand what the new week continues.

    DAILY SUMMARIES:

    #{daily_text}
    """
  end

  defp manual_chronicle do
    :froth
    |> Application.app_dir("priv/chronicle/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map_join("\n\n", &File.read!/1)
  end

  defp save(chat_id, from_date, to_date, text, daily, cycle_id) do
    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: day_start(from_date),
      to_date: day_start(Date.add(to_date, 1)),
      agent: @model,
      summary_text: text,
      message_count: Enum.sum(Enum.map(daily, &(&1.message_count || 0))),
      metadata: %{
        "kind" => @kind,
        "cycle_id" => cycle_id,
        "source_summary_ids" => Enum.map(daily, & &1.id)
      }
    })
    |> Repo.insert()
  end

  defp day_start(date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp date(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_date()
end
