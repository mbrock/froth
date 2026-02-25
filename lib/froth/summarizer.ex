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

  alias Froth.{Anthropic, ChatSummary, Repo}
  import Ecto.Query

  @model "claude-opus-4-6"
  @recent_context_chunk_size 50

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
    messages = fetch_messages(chat_id, from_unix, to_unix)

    if messages == [] do
      {:error, :no_messages}
    else
      session_id = default_telegram_session_id()
      sender_labels = sender_label_map(messages, session_id)
      msg_ids = Enum.map(messages, & &1.message_id)
      analyses_map = fetch_analyses_for_context(chat_id, msg_ids)
      transcript = format_transcript_with_analyses(messages, analyses_map, sender_labels)
      prior = fetch_prior_summaries(chat_id, from_unix)
      max_message_unix = max_message_unix(messages)
      prompt_to_unix = max_message_unix || to_unix
      covered_to_unix = summary_covered_to_unix(max_message_unix, to_unix)
      prompt = build_prompt(transcript, prior, from_unix, prompt_to_unix)

      on_event = fn
        {:text_delta, text} -> IO.write(text)
        {:thinking_delta, %{"delta" => t}} -> IO.write([IO.ANSI.faint(), t, IO.ANSI.reset()])
        {:thinking_stop, _} -> IO.write("\n---\n")
        _ -> :ok
      end

      api_opts = [system: @system_prompt, model: @model, tools: []]

      api_opts =
        case Keyword.get(opts, :api_key_name) do
          nil ->
            api_opts

          name ->
            case Froth.ApiKey.get(name) do
              %{key: key} -> Keyword.put(api_opts, :api_key, key)
              nil -> api_opts
            end
        end

      case Anthropic.stream_reply_with_tools(
             [%{role: :user, text: prompt}],
             on_event,
             api_opts
           ) do
        {:ok, %{text: text}} ->
          IO.write("\n")
          save(chat_id, from_unix, covered_to_unix, text, length(messages))

        {:error, _} = err ->
          err
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

  @doc """
  Build an XML-style context document for a chat: one <summary> tag per daily
  summary, then a `<recent>` section with verbatim messages after the last summary
  ends.
  """
  def context(chat_id, opts \\ []) do
    context_blocks(chat_id, opts)
    |> Enum.join("")
  end

  @doc """
  Build context as stable XML chunks suitable for prompt caching.

  The chunks preserve the exact context text emitted by `context/1`; they only
  introduce Anthropic content block boundaries so older parts can remain cacheable
  as new recent messages arrive.
  """
  def context_blocks(chat_id, opts \\ []) do
    before_unix = context_before_unix(opts)

    dailies =
      from(s in ChatSummary,
        where: s.chat_id == ^chat_id and s.from_date != s.to_date,
        where: fragment("? - ? <= 86400", s.to_date, s.from_date),
        order_by: [asc: s.from_date],
        select: %{from_date: s.from_date, to_date: s.to_date, summary_text: s.summary_text}
      )
      |> maybe_before_unix(before_unix)
      |> Repo.all(log: false)

    last_covered =
      case List.last(dailies) do
        nil -> 0
        s -> s.to_date
      end

    summary_entries =
      Enum.map(dailies, fn s ->
        date = DateTime.from_unix!(s.from_date) |> Calendar.strftime("%Y-%m-%d")
        "<summary date=\"#{date}\">\n#{s.summary_text}\n</summary>"
      end)

    summary_blocks =
      case summary_entries do
        [] ->
          []

        [first | rest] ->
          [first | Enum.map(rest, &("\n\n" <> &1))]
      end

    recent_msgs = fetch_recent_messages(chat_id, last_covered, before_unix)
    recent_blocks = build_recent_context_blocks(chat_id, recent_msgs, opts)
    summary_blocks ++ recent_blocks
  end

  defp fetch_recent_messages(chat_id, last_covered, nil) do
    fetch_messages(chat_id, last_covered, :infinity)
  end

  defp fetch_recent_messages(chat_id, last_covered, before_unix) when is_integer(before_unix) do
    fetch_messages(chat_id, last_covered, before_unix)
  end

  defp fetch_messages(chat_id, from_unix, :infinity) do
    Repo.all(
      from(m in "telegram_messages",
        where: m.chat_id == ^chat_id and m.date >= ^from_unix,
        order_by: [asc: m.date, asc: m.inserted_at],
        select: %{
          date: m.date,
          sender_id: m.sender_id,
          message_id: m.message_id,
          inserted_at: m.inserted_at,
          raw: m.raw
        }
      ),
      log: false
    )
    |> dedupe_messages()
  end

  defp fetch_messages(chat_id, from_unix, to_unix) do
    Repo.all(
      from(m in "telegram_messages",
        where: m.chat_id == ^chat_id and m.date >= ^from_unix and m.date < ^to_unix,
        order_by: [asc: m.date, asc: m.inserted_at],
        select: %{
          date: m.date,
          sender_id: m.sender_id,
          message_id: m.message_id,
          inserted_at: m.inserted_at,
          raw: m.raw
        }
      ),
      log: false
    )
    |> dedupe_messages()
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

  defp extract_text(raw) do
    get_in(raw, ["content", "text", "text"]) ||
      get_in(raw, ["content", "caption", "text"]) ||
      ""
  end

  defp fetch_analyses_for_context(_chat_id, []), do: %{}

  defp fetch_analyses_for_context(chat_id, message_ids) do
    Repo.all(
      from(a in Froth.Analysis,
        where: a.chat_id == ^chat_id and a.message_id in ^message_ids,
        select: %{
          id: a.id,
          type: a.type,
          message_id: a.message_id,
          analysis_text: a.analysis_text
        }
      ),
      log: false
    )
    |> Enum.group_by(& &1.message_id)
  end

  defp format_transcript_with_analyses(messages, analyses_map, sender_labels) do
    messages
    |> Enum.map(fn msg ->
      time = DateTime.from_unix!(msg.date) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
      sender = Map.get(sender_labels, msg.sender_id, "user:#{msg.sender_id || "unknown"}")
      text = extract_text(msg.raw)
      type = get_in(msg.raw, ["content", "@type"]) || "unknown"

      line =
        case type do
          "messageText" ->
            "[#{time}] #{sender} [msg:#{msg.message_id}]: #{text}"

          other ->
            media_note = String.replace(other, "message", "")

            if text != "" do
              "[#{time}] #{sender} [msg:#{msg.message_id}]: [#{media_note}] #{text}"
            else
              "[#{time}] #{sender} [msg:#{msg.message_id}]: [#{media_note}]"
            end
        end

      case Map.get(analyses_map, msg.message_id) do
        nil ->
          line

        [] ->
          line

        analyses ->
          snippets =
            Enum.map_join(analyses, "\n", fn a ->
              snippet =
                a.analysis_text
                |> String.slice(0, 150)
                |> String.replace(~r/\s+/, " ")
                |> String.trim()

              "  → analysis:#{a.id} (#{a.type}): #{snippet}…"
            end)

          line <> "\n" <> snippets
      end
    end)
    |> Enum.join("\n")
  end

  defp build_recent_context_blocks(_chat_id, [], _opts), do: []

  defp build_recent_context_blocks(chat_id, recent_msgs, opts) when is_list(recent_msgs) do
    session_id = context_session_id(opts)
    sender_labels = sender_label_map(recent_msgs, session_id)
    msg_ids = Enum.map(recent_msgs, & &1.message_id)
    analyses_map = fetch_analyses_for_context(chat_id, msg_ids)
    chunk_size = recent_context_chunk_size(opts)
    chunks = Enum.chunk_every(recent_msgs, chunk_size)
    last_idx = length(chunks) - 1

    Enum.with_index(chunks)
    |> Enum.map(fn {chunk, idx} ->
      transcript = format_transcript_with_analyses(chunk, analyses_map, sender_labels)

      prefix =
        if idx == 0 do
          "\n\n#{chat_context_block(chat_id, recent_msgs, session_id, sender_labels)}\n\n<recent>\n"
        else
          "\n"
        end

      suffix = if idx == last_idx, do: "\n</recent>", else: ""
      prefix <> transcript <> suffix
    end)
  end

  defp recent_context_chunk_size(opts) when is_list(opts) do
    default =
      Application.get_env(:froth, __MODULE__, [])
      |> Keyword.get(:recent_context_chunk_size, @recent_context_chunk_size)

    case Keyword.get(opts, :recent_chunk_size, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> @recent_context_chunk_size
    end
  end

  defp maybe_before_unix(query, nil), do: query

  defp maybe_before_unix(query, unix) when is_integer(unix),
    do: from(s in query, where: s.to_date <= ^unix)

  defp context_before_unix(opts) when is_list(opts) do
    case opts[:before_unix] do
      n when is_integer(n) ->
        n

      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp context_session_id(opts) when is_list(opts) do
    case opts[:telegram_session_id] do
      session_id when is_binary(session_id) and session_id != "" ->
        session_id

      _ ->
        default_telegram_session_id()
    end
  end

  defp default_telegram_session_id do
    Repo.one(
      from(s in Froth.Telegram.SessionConfig,
        where: s.enabled == true,
        order_by: [asc: s.id],
        select: s.id,
        limit: 1
      ),
      log: false
    )
  end

  defp sender_label_map(messages, session_id) when is_list(messages) do
    sender_ids =
      messages
      |> ordered_sender_ids()
      |> Enum.take(80)

    sender_ids
    |> Enum.map(fn sender_id ->
      {sender_id, resolve_sender_label(sender_id, session_id)}
    end)
    |> Map.new()
  end

  defp ordered_sender_ids(messages) when is_list(messages) do
    {_, ids} =
      Enum.reduce(messages, {MapSet.new(), []}, fn msg, {seen, acc} ->
        sender_id = msg.sender_id

        cond do
          not is_integer(sender_id) ->
            {seen, acc}

          MapSet.member?(seen, sender_id) ->
            {seen, acc}

          true ->
            {MapSet.put(seen, sender_id), acc ++ [sender_id]}
        end
      end)

    ids
  end

  defp resolve_sender_label(nil, _session_id), do: "unknown"

  defp resolve_sender_label(sender_id, session_id) when is_integer(sender_id) and sender_id > 0 do
    cache_key = {:summarizer_user_label, session_id, sender_id}

    case Process.get(cache_key) do
      nil ->
        label =
          case telegram_call(session_id, %{"@type" => "getUser", "user_id" => sender_id}) do
            {:ok, user} when is_map(user) -> user_label(user, sender_id)
            _ -> "user:#{sender_id}"
          end

        Process.put(cache_key, label)
        label

      label ->
        label
    end
  end

  defp resolve_sender_label(sender_id, session_id) when is_integer(sender_id) do
    cache_key = {:summarizer_sender_chat_label, session_id, sender_id}

    case Process.get(cache_key) do
      nil ->
        label =
          case telegram_call(session_id, %{"@type" => "getChat", "chat_id" => sender_id}) do
            {:ok, %{"title" => title}} when is_binary(title) and title != "" ->
              "#{title} (chat:#{sender_id})"

            _ ->
              "chat:#{sender_id}"
          end

        Process.put(cache_key, label)
        label

      label ->
        label
    end
  end

  defp user_label(user, user_id) when is_map(user) and is_integer(user_id) do
    username =
      case get_in(user, ["usernames", "active_usernames"]) do
        [u | _] when is_binary(u) and u != "" -> "@#{u}"
        _ -> nil
      end

    base =
      cond do
        is_binary(username) -> username
        true -> "user:#{user_id}"
      end

    sanitize_label(base)
  end

  defp user_label(_user, user_id), do: "user:#{user_id}"

  defp sanitize_label(label) when is_binary(label) do
    label
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp chat_context_block(chat_id, messages, session_id, sender_labels)
       when is_integer(chat_id) and is_list(messages) and is_map(sender_labels) do
    chat_name = chat_name(chat_id, session_id)
    sender_ids = ordered_sender_ids(messages)
    shown = Enum.take(sender_ids, 80)
    extra_count = max(length(sender_ids) - length(shown), 0)

    participant_lines =
      shown
      |> Enum.map(fn sender_id ->
        label = Map.get(sender_labels, sender_id, "user:#{sender_id}")
        "- #{label} [id=#{sender_id}]"
      end)
      |> case do
        [] -> ["- none"]
        lines -> lines
      end
      |> then(fn lines ->
        if extra_count > 0 do
          lines ++ ["- ... #{extra_count} more participants omitted"]
        else
          lines
        end
      end)
      |> Enum.join("\n")

    """
    <chat_context>
    chat_id=#{chat_id}
    chat_name=#{chat_name}
    participants_in_recent_window:
    #{participant_lines}
    </chat_context>
    """
    |> String.trim()
  end

  defp chat_name(chat_id, session_id) when is_integer(chat_id) do
    cache_key = {:summarizer_chat_name, session_id, chat_id}

    case Process.get(cache_key) do
      nil ->
        name =
          case telegram_call(session_id, %{"@type" => "getChat", "chat_id" => chat_id}) do
            {:ok, %{"title" => title}} when is_binary(title) and title != "" ->
              title

            _ ->
              "chat:#{chat_id}"
          end

        sanitized = sanitize_label(name)
        Process.put(cache_key, sanitized)
        sanitized

      name ->
        name
    end
  end

  defp telegram_call(session_id, request) when is_map(request) do
    session_id
    |> candidate_session_ids()
    |> Enum.reduce_while({:error, :no_session}, fn sid, _acc ->
      case safe_telegram_call(sid, request) do
        {:ok, _} = ok -> {:halt, ok}
        _ -> {:cont, {:error, :telegram_unavailable}}
      end
    end)
  end

  defp candidate_session_ids(session_id) when is_binary(session_id) and session_id != "" do
    [session_id | enabled_session_ids()]
    |> Enum.uniq()
  end

  defp candidate_session_ids(_), do: enabled_session_ids()

  defp enabled_session_ids do
    Repo.all(
      from(s in Froth.Telegram.SessionConfig,
        where: s.enabled == true,
        order_by: [asc: s.id],
        select: s.id
      ),
      log: false
    )
  end

  defp safe_telegram_call(session_id, request)
       when is_binary(session_id) and session_id != "" and is_map(request) do
    try do
      Froth.Telegram.call(session_id, request, 5_000)
    rescue
      _ -> {:error, :telegram_unavailable}
    catch
      _, _ -> {:error, :telegram_unavailable}
    end
  end

  defp safe_telegram_call(_, _), do: {:error, :no_session}

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
    #{context}Summarize the following chat transcript from #{from_str} to #{to_str}.

    TRANSCRIPT:
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

  defp save(chat_id, from_unix, to_unix, text, message_count) do
    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: from_unix,
      to_date: to_unix,
      agent: @model,
      summary_text: text,
      message_count: message_count,
      metadata: %{},
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end
end
