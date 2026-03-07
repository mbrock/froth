defmodule Froth.Summarizer do
  @moduledoc """
  Generates LLM summaries of telegram message ranges and stores them in the DB.

  Usage:
    # Summarize a specific unix timestamp range
    Froth.Summarizer.summarize(chat_id, from_unix, to_unix)

    # Summarize a calendar day (UTC)
    Froth.Summarizer.summarize_day(chat_id, ~D[2026-02-05])

    # List existing summaries
    Froth.Summarizer.list(chat_id)
  """

  alias Froth.{ChatSummary, Repo}
  alias Froth.Agent
  alias Froth.Agent.{Config, Message}
  alias Froth.Telegram.BotContext
  import Ecto.Query

  @model "claude-opus-4-6"

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

  def summarize(chat_id, from_unix, to_unix, _opts \\ [])
      when is_integer(from_unix) and is_integer(to_unix) do
    messages = BotContext.fetch_messages(chat_id, from_unix, to_unix)

    if messages == [] do
      {:error, :no_messages}
    else
      transcript = BotContext.transcript_with_analyses(chat_id, messages)
      prior = fetch_prior_summaries(chat_id, from_unix)
      max_message_unix = max_message_unix(messages)
      prompt_to_unix = max_message_unix || to_unix
      covered_to_unix = summary_covered_to_unix(max_message_unix, to_unix)
      prompt = build_prompt(transcript, prior, from_unix, prompt_to_unix)

      config = %Config{system: @system_prompt, model: @model, tools: []}
      user_msg = Repo.insert!(%Message{role: :user, content: Message.wrap(prompt)})
      {cycle, stream} = Agent.run(user_msg, config)

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

          {:event, _event, %{role: :agent} = msg}, _acc ->
            Message.extract_text(msg.content)

          _, acc ->
            acc
        end)

      IO.write("\n")

      if text do
        save(chat_id, from_unix, covered_to_unix, text, length(messages), cycle.id)
      else
        {:error, :no_response}
      end
    end
  end

  def summarize_day(chat_id, %Date{} = date) do
    from_unix = date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    to_unix = date |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    summarize(chat_id, from_unix, to_unix)
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
    Repo.all(
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.to_date <= ^before_unix,
        order_by: [asc: s.from_date],
        select: %{from_date: s.from_date, to_date: s.to_date, summary_text: s.summary_text}
      ),
      log: false
    )
  end

  defp build_prompt(transcript, prior_summaries, from_unix, to_unix) do
    from_str = DateTime.from_unix!(from_unix) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    to_str = DateTime.from_unix!(to_unix) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

    context =
      if prior_summaries != [] do
        prior_text =
          prior_summaries
          |> Enum.map(fn s ->
            f = DateTime.from_unix!(s.from_date) |> Calendar.strftime("%Y-%m-%d")
            t = DateTime.from_unix!(s.to_date) |> Calendar.strftime("%Y-%m-%d")
            "--- #{f} to #{t} ---\n#{s.summary_text}"
          end)
          |> Enum.join("\n\n")

        "Here are the previous summaries for context:\n\n#{prior_text}\n\n---\n\n"
      else
        ""
      end

    """
    #{context}Summarize the following chat context from #{from_str} to #{to_str}.

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

  defp summary_covered_to_unix(nil, to_unix) when is_integer(to_unix), do: to_unix

  defp summary_covered_to_unix(max_message_unix, to_unix)
       when is_integer(max_message_unix) and is_integer(to_unix) do
    min(to_unix, max_message_unix + 1)
  end

  defp save(chat_id, from_unix, to_unix, text, message_count, cycle_id) do
    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: from_unix,
      to_date: to_unix,
      agent: @model,
      summary_text: text,
      message_count: message_count,
      metadata: if(cycle_id, do: %{"cycle_id" => cycle_id}, else: %{}),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end
end
