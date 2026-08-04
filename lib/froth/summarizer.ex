defmodule Froth.Summarizer do
  @moduledoc """
  Generates LLM summaries of telegram message ranges and stores them in the DB.

  Usage:
    # Summarize a specific unix timestamp range
    Froth.Summarizer.summarize(chat_id, from_unix, to_unix)

    # Summarize a calendar day (UTC)
    Froth.Summarizer.summarize_day(chat_id, ~D[2026-02-05])

    # List pending daily summary dates up to yesterday (UTC)
    Froth.Summarizer.pending_summary_dates(chat_id)

    # List existing summaries
    Froth.Summarizer.list(chat_id)
  """

  alias Froth.{ChatSummary, NarrativeContext, Repo}
  alias Froth.Agent
  alias Froth.Agent.{Config, Message}
  alias Froth.Telegram.{BotContext, Queries}
  import Ecto.Query

  @model "claude-opus-5"
  @max_tokens 65_536
  @preliminary_kind "preliminary_daily"

  @system_prompt """
  You are writing a narrative daily summary of a Telegram group chat. \
  Write in the style of a dense, precise editorial recap — not bullet points, not a chatbot summary. \
  Each summary should read like a paragraph from a well-edited chronicle: \
  who said what, what happened, what the significance is. \
  Name the participants. Describe the arc of the day. \
  Be specific about the content of conversations, not vague. \
  If technical work happened, say what was built or broken. \
  If philosophical discussion happened, name the actual ideas. \
  One to three paragraphs. No headers, no bullets, no emoji.
  """

  def summarize(chat_id, from_unix, to_unix, opts \\ [])
      when is_integer(from_unix) and is_integer(to_unix) do
    messages = Queries.fetch_messages(chat_id, from_unix, to_unix)

    if messages == [] do
      {:error, :no_messages}
    else
      transcript = BotContext.for_messages(chat_id, messages) |> Enum.join("")
      prior = fetch_prior_summaries(chat_id, from_unix)
      max_message_unix = max_message_unix(messages)
      prompt_to_unix = max_message_unix || to_unix
      covered_to_unix = summary_covered_to_unix(max_message_unix, to_unix)

      prompt =
        build_prompt(
          transcript,
          prior,
          from_unix,
          prompt_to_unix,
          Keyword.get(opts, :preliminary, false)
        )

      config = %Config{
        system: @system_prompt,
        model: @model,
        max_tokens: @max_tokens,
        tools: []
      }

      user_msg = Message.user(prompt)

      agent_run_fun = Keyword.get(opts, :agent_run_fun, &Agent.run/2)
      {cycle, stream} = agent_run_fun.(user_msg, config)

      text =
        stream
        |> Enum.reduce(nil, fn
          {:stream, {:text_delta, delta}}, _acc ->
            IO.write(delta)
            nil

          {:stream, {:thinking_delta, %{"delta" => t}}}, _acc ->
            IO.write([IO.ANSI.faint(), t, IO.ANSI.reset()])
            nil

          {:stream, {:thinking_stop, _}}, _acc ->
            IO.write("\n---\n")
            nil

          {:message, %{role: :agent} = msg}, _acc ->
            Message.extract_text(msg.content)

          _, acc ->
            acc
        end)

      IO.write("\n")

      if text do
        save(
          chat_id,
          from_unix,
          covered_to_unix,
          text,
          length(messages),
          cycle.id,
          Keyword.get(opts, :preliminary, false)
        )
      else
        {:error, :no_response}
      end
    end
  end

  def summarize_day(chat_id, %Date{} = date, opts \\ []) do
    from_unix =
      date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    to_unix =
      date
      |> Date.add(1)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix()

    summarize(chat_id, from_unix, to_unix, opts)
  end

  @doc """
  Refresh today's amendable summary after enough unsummarized context accrues.

  The summary covers the whole UTC day so far, while the threshold is measured
  only from the end of the previous preliminary summary. This advances the
  standing-context floor without losing continuity.
  """
  def maybe_summarize_preliminary(chat_id, opts \\ [])
      when is_integer(chat_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    threshold = Keyword.get(opts, :char_threshold, 200_000)
    date = DateTime.to_date(now)
    day_start = day_start_unix(date)
    to_unix = DateTime.to_unix(now)
    existing = preliminary_summary(chat_id, day_start)
    floor = if existing, do: existing.to_date, else: day_start
    messages = Queries.fetch_messages(chat_id, floor, to_unix)

    chars =
      chat_id |> BotContext.render_for_messages(messages) |> String.length()

    if chars >= threshold do
      summarize(chat_id, day_start, to_unix,
        preliminary: true,
        agent_run_fun: Keyword.get(opts, :agent_run_fun, &Agent.run/2)
      )
    else
      {:ok, nil}
    end
  end

  def pending_summary_dates(chat_id, today \\ Date.utc_today()) do
    cutoff_date = Date.add(today, -1)

    case latest_summary_date(chat_id) do
      nil ->
        []

      latest_date ->
        if Date.compare(latest_date, cutoff_date) == :lt do
          latest_date
          |> Date.add(1)
          |> Date.range(cutoff_date)
          |> Enum.to_list()
        else
          []
        end
    end
  end

  def list(chat_id) do
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id,
        order_by: [asc: s.from_date]
      )
    )
  end

  defp fetch_prior_summaries(chat_id, before_unix) do
    NarrativeContext.for_daily_summary(chat_id, before_unix)
  end

  defp latest_summary_date(chat_id) do
    Repo.one(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.from_date != s.to_date,
        where: fragment("? - ? <= 86400", s.to_date, s.from_date),
        where:
          fragment(
            "COALESCE(?->>'kind', '') != ?",
            s.metadata,
            @preliminary_kind
          ),
        order_by: [desc: s.from_date],
        limit: 1,
        select: s.from_date
      ),
      log: false
    )
    |> case do
      nil -> nil
      from_unix -> DateTime.from_unix!(from_unix) |> DateTime.to_date()
    end
  end

  defp build_prompt(
         transcript,
         prior_summaries,
         from_unix,
         to_unix,
         preliminary?
       ) do
    from_str =
      DateTime.from_unix!(from_unix)
      |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

    to_str =
      DateTime.from_unix!(to_unix) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

    context =
      if prior_summaries != [] do
        prior_text =
          prior_summaries
          |> Enum.map(fn s ->
            f =
              DateTime.from_unix!(s.from_date)
              |> Calendar.strftime("%Y-%m-%d")

            t =
              DateTime.from_unix!(s.to_date) |> Calendar.strftime("%Y-%m-%d")

            "--- #{f} to #{t} ---\n#{s.summary_text}"
          end)
          |> Enum.join("\n\n")

        "Here are the previous summaries for context:\n\n#{prior_text}\n\n---\n\n"
      else
        ""
      end

    preliminary_instruction =
      if preliminary? do
        """
        This is a preliminary summary of the current UTC day while it is still
        in progress. Capture the day so far as a coherent narrative, without
        implying that its stories or arguments are finished. This summary will
        be amended as more conversation arrives and finalized after midnight.

        """
      else
        ""
      end

    """
    #{context}#{preliminary_instruction}Summarize the following chat context from #{from_str} to #{to_str}.

    CONTEXT:
    #{transcript}
    """
  end

  defp max_message_unix(messages) when is_list(messages) do
    messages
    |> Enum.map(&Map.get(&1, :date))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp summary_covered_to_unix(nil, to_unix) when is_integer(to_unix),
    do: to_unix

  defp summary_covered_to_unix(max_message_unix, to_unix)
       when is_integer(max_message_unix) and is_integer(to_unix) do
    min(to_unix, max_message_unix + 1)
  end

  defp save(
         chat_id,
         from_unix,
         to_unix,
         text,
         message_count,
         cycle_id,
         preliminary?
       ) do
    summary = preliminary_summary(chat_id, from_unix) || %ChatSummary{}

    metadata =
      %{}
      |> then(fn metadata ->
        if cycle_id,
          do: Map.put(metadata, "cycle_id", cycle_id),
          else: metadata
      end)
      |> then(fn metadata ->
        if preliminary?,
          do: Map.put(metadata, "kind", @preliminary_kind),
          else: metadata
      end)

    summary
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: from_unix,
      to_date: to_unix,
      agent: @model,
      summary_text: text,
      message_count: message_count,
      metadata: metadata,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert_or_update()
  end

  defp preliminary_summary(chat_id, from_unix) do
    Repo.one(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.from_date == ^from_unix,
        where: fragment("?->>'kind' = ?", s.metadata, @preliminary_kind),
        order_by: [desc: s.inserted_at],
        limit: 1
      ),
      log: false
    )
  end

  defp day_start_unix(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end
end
