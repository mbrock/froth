defmodule Froth.Analyzer.Discovery do
  @moduledoc "Find unanalyzed messages and enqueue Oban jobs."

  import Ecto.Query
  alias Froth.Repo

  @youtube_re ~r{https?://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]+)}
  @xpost_re ~r{https?://(?:x\.com|twitter\.com)/\w+/status/(\d+)}

  # The single source of truth for message type → worker mapping.
  # Returns [{type_string, worker_module, extra_args}] for a raw TDLib message.
  def classify(raw) do
    content_type = get_in(raw, ["content", "@type"])
    text = get_in(raw, ["content", "text", "text"]) || ""

    mime = get_in(raw, ["content", "document", "mime_type"]) || ""

    media =
      case content_type do
        "messagePhoto" ->
          [{"image", Froth.Analyzer.ImageWorker, %{}}]

        "messageVoiceNote" ->
          [{"voice", Froth.Analyzer.VoiceWorker, %{}}]

        "messageAudio" ->
          [{"voice", Froth.Analyzer.VoiceWorker, %{}}]

        "messageVideo" ->
          [{"video", Froth.Analyzer.VideoWorker, %{}}]

        "messageDocument" when mime == "application/pdf" ->
          [{"pdf", Froth.Analyzer.PdfWorker, %{}}]

        _ ->
          []
      end

    text_matches =
      []
      |> maybe_match(text, @youtube_re, "youtube", Froth.Analyzer.YouTubeWorker)
      |> maybe_match(text, @xpost_re, "xpost", Froth.Analyzer.XPostWorker)

    media ++ text_matches
  end

  defp maybe_match(acc, text, regex, type, worker) do
    if Regex.match?(regex, text),
      do: [{type, worker, %{text: text}} | acc],
      else: acc
  end

  # Classify and enqueue jobs for a single message (called from Sync on new messages).
  # Only analyzes messages from chats that have summaries (i.e. actively monitored chats).
  def discover_message(chat_id, message_id, raw) do
    if analyzed_chat?(chat_id) do
      classify(raw)
      |> Enum.each(fn {type, worker, extra} ->
        unless already_analyzed?(type, chat_id, message_id) do
          args = Map.merge(%{chat_id: chat_id, message_id: message_id}, extra)
          Oban.insert(worker.new(args))
        end
      end)
    end
  end

  defp analyzed_chat?(chat_id) do
    from(s in "chat_summaries", where: s.chat_id == ^chat_id)
    |> Repo.exists?(log: false)
  end

  defp already_analyzed?(type, chat_id, message_id) do
    from(a in "analyses",
      where: a.type == ^type and a.chat_id == ^chat_id and a.message_id == ^message_id
    )
    |> Repo.exists?(log: false)
  end

  # Bulk discovery — scans DB for all unanalyzed messages.
  def discover_all(chat_id \\ nil) do
    messages = load_messages(chat_id)

    results =
      messages
      |> Enum.flat_map(fn %{chat_id: cid, message_id: mid, raw: raw} ->
        classify(raw)
        |> Enum.map(fn {type, worker, extra} ->
          {type, worker, Map.merge(%{chat_id: cid, message_id: mid}, extra)}
        end)
      end)
      |> Enum.group_by(fn {type, _worker, _args} -> type end)

    total =
      Enum.reduce(results, 0, fn {type, entries}, acc ->
        args_list = Enum.map(entries, fn {_, _, args} -> args end)
        worker = entries |> hd() |> elem(1)

        filtered = reject_already_analyzed(args_list, type)
        enqueue_jobs(filtered, worker)

        acc + length(filtered)
      end)

    IO.puts("enqueued #{total} jobs")
    total
  end

  defp load_messages(chat_id) do
    query =
      from(m in "telegram_messages",
        select: %{chat_id: m.chat_id, message_id: m.message_id, raw: m.raw}
      )

    query = if chat_id, do: where(query, [m], m.chat_id == ^chat_id), else: query
    Repo.all(query, log: false)
  end

  defp reject_already_analyzed(messages, type) do
    existing =
      from(a in "analyses",
        where: a.type == ^type,
        select: {a.chat_id, a.message_id}
      )
      |> Repo.all(log: false)
      |> MapSet.new()

    Enum.reject(messages, fn %{chat_id: cid, message_id: mid} ->
      MapSet.member?(existing, {cid, mid})
    end)
  end

  defp enqueue_jobs(messages, worker_module) do
    jobs =
      Enum.map(messages, fn msg ->
        args = Map.take(msg, [:chat_id, :message_id, :text])
        worker_module.new(args)
      end)

    Oban.insert_all(jobs)
  end
end
