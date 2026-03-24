defmodule Froth.Telegram.BotContext do
  @moduledoc """
  Builds context for Telegram bot conversations.

  All public functions return rendered parts (list of strings),
  suitable for prompt caching. Join them for a single string,
  or wrap them for an API call — that's up to the caller.
  """

  alias Froth.Agent
  alias Froth.Telegram.BotContextHTML
  alias Froth.Telegram.BotContextHTML.Context
  alias Froth.Telegram.{Names, Queries}

  # ── public API ─────────────────────────────────────────────────────

  @doc """
  Build context parts for a chat, using summaries + recent messages from the DB.
  """
  def render_parts(chat_id, opts \\ []) do
    chat_id
    |> build(opts)
    |> render()
  end

  @doc """
  Build context parts for an incoming message in a bot conversation.
  Includes DB history up to the message, plus the message itself.

  Returns `nil` for malformed input.
  """
  def for_message(%{"chat_id" => chat_id} = msg, bot_config)
      when is_integer(chat_id) and is_map(bot_config) do
    opts = message_opts(msg, bot_config)
    prefix = build(chat_id, opts)
    incoming = build_incoming([msg], opts)

    %Context{prefix | recent_messages: prefix.recent_messages ++ incoming}
    |> render()
  end

  def for_message(_msg, _bot_config), do: nil

  @doc """
  Build context parts for a pre-fetched list of DB message rows.
  Used by the summarizer.
  """
  def for_messages(chat_id, messages, opts \\ [])
      when is_integer(chat_id) and is_list(messages) do
    recent = build_recent(chat_id, messages, opts)

    %Context{chat_context: recent.chat_context, recent_messages: recent.recent_messages}
    |> render()
  end

  # ── building the view model ────────────────────────────────────

  defp build(chat_id, opts) when is_integer(chat_id) and is_list(opts) do
    before_unix = opt_before_unix(opts)

    {summaries, last_covered} =
      case {opt_include_summaries(opts), opts[:lore_file]} do
        {false, _} ->
          {[], 0}

        {true, path} when is_binary(path) ->
          # Compressed lore mode: read a single file instead of 40 DB summaries
          text = File.read!(path)

          last_covered =
            case Queries.latest_daily_summary_end(chat_id, before_unix) do
              unix when is_integer(unix) -> unix
              _ -> 0
            end

          {[%{date: "lore", text: text}], last_covered}

        {true, _} ->
          dailies = Queries.daily_summaries(chat_id, before_unix)

          last_covered =
            case List.last(dailies) do
              nil -> 0
              s -> s.to_date
            end

          summaries =
            Enum.map(dailies, fn s ->
              %{
                date: DateTime.from_unix!(s.from_date) |> Calendar.strftime("%Y-%m-%d"),
                text: s.summary_text
              }
            end)

          {summaries, last_covered}
      end

    db_rows = fetch_recent(chat_id, last_covered, before_unix)
    db_rows = limit_recent_rows(db_rows, opts)
    recent = build_recent(chat_id, db_rows, opts)

    %Context{
      summaries: summaries,
      chat_context: recent.chat_context,
      recent_messages: recent.recent_messages
    }
  end

  defp render(%Context{} = ctx) do
    ctx
    |> then(&BotContextHTML.context(%{ctx: &1}))
    |> BotContextHTML.render_to_parts()
  end

  # ── message normalization ─────────────────────────────────────────

  defp normalize_incoming(msg) when is_map(msg) do
    %{
      date: msg_unix(msg),
      sender_id:
        get_in(msg, ["sender_id", "user_id"]) ||
          get_in(msg, ["sender_id", "chat_id"]) ||
          integer_sender_id(msg["sender_id"]),
      message_id: msg["id"] || "unknown",
      type: get_in(msg, ["content", "@type"]) || "unknown",
      text:
        get_in(msg, ["content", "text", "text"]) ||
          get_in(msg, ["content", "caption", "text"]) || ""
    }
  end

  defp normalize_db_row(msg) when is_map(msg) do
    %{
      date: msg.date,
      sender_id: msg.sender_id,
      message_id: msg.message_id,
      type: get_in(msg.raw, ["content", "@type"]) || "unknown",
      text:
        get_in(msg.raw, ["content", "text", "text"]) ||
          get_in(msg.raw, ["content", "caption", "text"]) || ""
    }
  end

  # ── context assembly ──────────────────────────────────────────────

  defp build_incoming(messages, opts) do
    session_id = opt_session_id(opts)

    normalized =
      messages
      |> sort_messages()
      |> Enum.map(&normalize_incoming/1)

    sender_labels = Names.sender_label_map(normalized, session_id)
    Enum.map(normalized, &to_recent_message(&1, sender_labels))
  end

  defp fetch_recent(chat_id, last_covered, nil),
    do: Queries.fetch_messages(chat_id, last_covered, :infinity)

  defp fetch_recent(chat_id, last_covered, before_unix) when is_integer(before_unix),
    do: Queries.fetch_messages(chat_id, last_covered, before_unix)

  defp build_recent(_chat_id, [], _opts),
    do: %{chat_context: nil, recent_messages: []}

  defp build_recent(chat_id, db_rows, opts) do
    session_id = opt_session_id(opts)
    normalized = Enum.map(db_rows, &normalize_db_row/1)
    sender_labels = Names.sender_label_map(normalized, session_id)
    msg_ids = Enum.map(normalized, & &1.message_id)
    analyses_map = Queries.analyses_for_messages(chat_id, msg_ids)
    cycle_traces_map = build_cycle_traces_map(chat_id, msg_ids, opts)

    recent_messages =
      Enum.map(normalized, fn msg ->
        msg
        |> to_recent_message(sender_labels)
        |> Map.put(:analyses, truncate_analyses(Map.get(analyses_map, msg.message_id, [])))
        |> Map.put(:cycles, Map.get(cycle_traces_map, msg.message_id, []))
      end)

    %{
      chat_context: %{
        chat_id: chat_id,
        chat_name: Names.chat_name(chat_id, session_id),
        participants: Enum.map(sender_labels, fn {id, label} -> %{id: id, label: label} end),
        omitted_count: 0
      },
      recent_messages: recent_messages
    }
  end

  defp to_recent_message(msg, sender_labels) do
    %{
      date: msg.date,
      sender: Map.get(sender_labels, msg.sender_id, fallback_sender(msg.sender_id)),
      message_id: msg.message_id,
      type: msg.type,
      text: msg.text,
      analyses: [],
      cycles: []
    }
  end

  defp fallback_sender(nil), do: "unknown"
  defp fallback_sender(id), do: "user:#{id}"

  defp integer_sender_id(sender_id) when is_integer(sender_id), do: sender_id
  defp integer_sender_id(_sender_id), do: nil

  defp truncate_analyses(analyses) do
    Enum.map(analyses, fn a ->
      clean = a.analysis_text |> String.replace(~r/\s+/, " ") |> String.trim()
      snippet = String.slice(clean, 0, 150)
      suffix = if String.length(clean) > 150, do: "…", else: ""
      %{id: a.id, type: a.type, text: snippet <> suffix}
    end)
  end

  defp build_cycle_traces_map(chat_id, msg_ids, opts) do
    Queries.cycle_traces_for_messages(chat_id, msg_ids, bot_id: opt_bot_id(opts))
    |> Map.new(fn {message_id, links} ->
      traces =
        links
        |> Enum.map(&build_cycle_trace/1)
        |> Enum.reject(&is_nil/1)

      {message_id, traces}
    end)
  end

  defp build_cycle_trace(%{cycle_id: cycle_id, inserted_at: inserted_at}) do
    case Agent.cycle_trace(cycle_id) do
      [] -> nil
      entries -> %{cycle_id: cycle_id, inserted_at: inserted_at, entries: entries}
    end
  end

  # ── options ───────────────────────────────────────────────────────

  defp message_opts(msg, bot_config) do
    base = [telegram_session_id: bot_config.session_id, bot_id: bot_config.id]
    base = if lf = Map.get(bot_config, :lore_file), do: [{:lore_file, lf} | base], else: base
    base = [{:include_summaries, Map.get(bot_config, :include_summaries, true)} | base]
    base = maybe_put_opt(base, :recent_message_limit, Map.get(bot_config, :recent_message_limit))

    case msg_unix(msg) do
      unix when is_integer(unix) -> [{:before_unix, unix} | base]
      _ -> base
    end
  end

  defp opt_before_unix(opts) do
    case opts[:before_unix] do
      n when is_integer(n) -> n
      v when is_binary(v) -> parse_int(v)
      _ -> nil
    end
  end

  defp opt_session_id(opts) do
    case opts[:telegram_session_id] do
      id when is_binary(id) and id != "" -> id
      _ -> Queries.default_session_id()
    end
  end

  defp opt_bot_id(opts) do
    case opts[:bot_id] do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp opt_include_summaries(opts) do
    case opts[:include_summaries] do
      false -> false
      _ -> true
    end
  end

  defp opt_recent_message_limit(opts) do
    case opts[:recent_message_limit] do
      n when is_integer(n) and n > 0 -> n
      v when is_binary(v) -> parse_int(v)
      _ -> nil
    end
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp limit_recent_rows(rows, opts) when is_list(rows) and is_list(opts) do
    case opt_recent_message_limit(opts) do
      n when is_integer(n) and n > 0 -> Enum.take(rows, -n)
      _ -> rows
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: [{key, value} | opts]

  defp msg_unix(%{"date" => v}) when is_integer(v), do: v
  defp msg_unix(%{"date" => v}) when is_binary(v), do: parse_int(v)
  defp msg_unix(_), do: nil

  defp parse_int(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, fn msg ->
      case msg["id"] do
        n when is_integer(n) -> n
        s when is_binary(s) -> parse_int(s) || 0
        _ -> 0
      end
    end)
  end
end
