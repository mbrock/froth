defmodule Froth.Telegram.BotContext do
  @moduledoc """
  Builds the initial user content payload for Telegram bot cycles.
  """

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.{Analysis, ChatSummary}
  alias Froth.Repo
  alias Froth.Telegram.BotContextHTML
  alias Froth.Telegram.BotContextHTML.Context
  alias Froth.Telegram.CycleLink

  @response_instruction "\n\nNow reply using the send_message tool."
  # @recap_max_tokens_approx 20_000

  # ── public API ─────────────────────────────────────────────────────

  @doc """
  Build an XML-style context document for a chat.
  """
  def context(chat_id, opts \\ []) do
    context_parts(chat_id, opts)
    |> Enum.join("")
  end

  @doc """
  Build context as stable XML chunks suitable for prompt caching.
  """
  def context_parts(chat_id, opts \\ []) do
    ctx = context_view_model(chat_id, opts)
    BotContextHTML.render_to_parts(BotContextHTML.context(%{ctx: ctx}))
  end

  @doc """
  Build the shared `%Context{}` view model for context rendering.
  """
  def context_view_model(chat_id, opts \\ []) when is_integer(chat_id) and is_list(opts) do
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

    summaries =
      Enum.map(dailies, fn s ->
        %{
          date: DateTime.from_unix!(s.from_date) |> Calendar.strftime("%Y-%m-%d"),
          text: s.summary_text
        }
      end)

    recent_msgs = fetch_recent_messages(chat_id, last_covered, before_unix)
    recent_context = build_recent_context_assigns(chat_id, recent_msgs, opts)

    %Context{
      summaries: summaries,
      chat_context: recent_context.chat_context,
      recent_messages: recent_context.recent_messages
    }
  end

  @doc false
  def fetch_messages(chat_id, from_unix, to_unix)
      when is_integer(chat_id) and is_integer(from_unix) and is_integer(to_unix) do
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

  @doc false
  def fetch_messages(chat_id, from_unix, :infinity)
      when is_integer(chat_id) and is_integer(from_unix) do
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

  @doc false
  def transcript_with_analyses(chat_id, messages, opts \\ [])
      when is_integer(chat_id) and is_list(messages) and is_list(opts) do
    recent_context = build_recent_context_assigns(chat_id, messages, opts)

    ctx = %Context{
      chat_context: recent_context.chat_context,
      recent_messages: recent_context.recent_messages
    }

    BotContextHTML.render_to_string(BotContextHTML.context(%{ctx: ctx}))
  end

  @doc """
  Build the initial user message content as text blocks for Anthropic.

  Returns `nil` for malformed input.
  """
  def build_context(%{"chat_id" => chat_id} = msg, bot_config)
      when is_integer(chat_id) and is_map(bot_config) do
    context_opts = initial_context_opts(msg, bot_config)
    prefix_ctx = context_view_model(chat_id, context_opts)
    incoming_recent_messages = build_incoming_recent_messages([msg], context_opts)

    ctx = %Context{
      prefix_ctx
      | recent_messages: prefix_ctx.recent_messages ++ incoming_recent_messages
    }

    ctx
    |> then(&BotContextHTML.context(%{ctx: &1}))
    |> BotContextHTML.render_to_parts()
    |> append_response_instruction()
    |> to_text_blocks()
  end

  def build_context(_msg, _bot_config), do: nil

  # ── data extraction ────────────────────────────────────────────────

  defp build_incoming_recent_messages(messages, opts) when is_list(messages) and is_list(opts) do
    session_id = context_session_id(opts)

    messages
    |> sort_messages()
    |> Enum.map(&to_incoming_recent_message/1)
    |> then(fn incoming ->
      sender_labels = sender_label_map(incoming, session_id)
      Enum.map(incoming, &format_incoming_recent_message(&1, sender_labels))
    end)
  end

  defp to_incoming_recent_message(msg) when is_map(msg) do
    sender_id =
      get_in(msg, ["sender_id", "user_id"]) ||
        get_in(msg, ["sender_id", "chat_id"])

    unix = message_unix(msg)

    %{
      date: unix,
      sender_id: sender_id,
      message_id: msg["id"] || "unknown",
      type: get_in(msg, ["content", "@type"]) || "unknown",
      text:
        get_in(msg, ["content", "text", "text"]) ||
          get_in(msg, ["content", "caption", "text"]) || ""
    }
  end

  defp format_incoming_recent_message(msg, sender_labels)
       when is_map(msg) and is_map(sender_labels) do
    %{
      time: format_recent_time(msg.date),
      sender: Map.get(sender_labels, msg.sender_id, fallback_sender_label(msg.sender_id)),
      message_id: msg.message_id,
      type: msg.type,
      text: msg.text,
      analyses: [],
      cycles: []
    }
  end

  defp format_recent_time(unix) when is_integer(unix) do
    DateTime.from_unix!(unix) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp format_recent_time(_), do: "unknown"

  defp fallback_sender_label(nil), do: "unknown"
  defp fallback_sender_label(sender_id), do: "user:#{sender_id}"

  defp fetch_recent_messages(chat_id, last_covered, nil) do
    fetch_messages(chat_id, last_covered, :infinity)
  end

  defp fetch_recent_messages(chat_id, last_covered, before_unix) when is_integer(before_unix) do
    fetch_messages(chat_id, last_covered, before_unix)
  end

  defp build_recent_context_assigns(_chat_id, [], _opts) do
    %{chat_context: nil, recent_messages: []}
  end

  defp build_recent_context_assigns(chat_id, recent_msgs, opts) when is_list(recent_msgs) do
    session_id = context_session_id(opts)
    sender_labels = sender_label_map(recent_msgs, session_id)
    msg_ids = Enum.map(recent_msgs, & &1.message_id)
    analyses_map = fetch_analyses_for_context(chat_id, msg_ids)
    cycle_traces_map = fetch_cycle_traces_for_context(chat_id, msg_ids, opts)

    recent_messages =
      Enum.map(recent_msgs, fn msg ->
        format_recent_message(msg, sender_labels, analyses_map, cycle_traces_map)
      end)

    %{
      chat_context: build_chat_context(chat_id, recent_msgs, session_id, sender_labels),
      recent_messages: recent_messages
    }
  end

  defp fetch_analyses_for_context(_chat_id, []), do: %{}

  defp fetch_analyses_for_context(chat_id, message_ids) do
    Repo.all(
      from(a in Analysis,
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

  defp fetch_cycle_traces_for_context(_chat_id, [], _opts), do: %{}

  defp fetch_cycle_traces_for_context(chat_id, message_ids, opts)
       when is_integer(chat_id) and is_list(message_ids) and is_list(opts) do
    query =
      from(l in CycleLink,
        join: c in Cycle,
        on: c.id == l.cycle_id,
        where: l.chat_id == ^chat_id and l.reply_to in ^message_ids,
        order_by: [asc: c.inserted_at],
        select: %{message_id: l.reply_to, cycle_id: l.cycle_id, inserted_at: c.inserted_at}
      )

    query =
      case context_bot_id(opts) do
        bot_id when is_binary(bot_id) and bot_id != "" ->
          from([l, c] in query, where: l.bot_id == ^bot_id)

        _ ->
          query
      end

    Repo.all(query, log: false)
    |> Enum.group_by(& &1.message_id)
    |> Map.new(fn {message_id, links} ->
      traces =
        links
        |> Enum.map(&build_cycle_trace/1)
        |> Enum.reject(&is_nil/1)

      {message_id, traces}
    end)
  end

  defp build_cycle_trace(%{cycle_id: cycle_id, inserted_at: inserted_at}) do
    entries =
      cycle_id
      |> load_cycle_api_messages()
      |> extract_session_entries()

    if entries == [] do
      nil
    else
      %{
        cycle_id: cycle_id,
        time: format_cycle_time(inserted_at),
        entries: entries
      }
    end
  end

  defp format_cycle_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_cycle_time(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_cycle_time(other), do: to_string(other)

  defp format_recent_message(msg, sender_labels, analyses_map, cycle_traces_map) do
    %{
      time: DateTime.from_unix!(msg.date) |> Calendar.strftime("%Y-%m-%d %H:%M UTC"),
      sender: Map.get(sender_labels, msg.sender_id, "user:#{msg.sender_id || "unknown"}"),
      message_id: msg.message_id,
      type: get_in(msg.raw, ["content", "@type"]) || "unknown",
      text: extract_text(msg.raw),
      analyses: format_analysis_excerpts(Map.get(analyses_map, msg.message_id, [])),
      cycles: Map.get(cycle_traces_map, msg.message_id, [])
    }
  end

  defp format_analysis_excerpts(analyses) when is_list(analyses) do
    Enum.map(analyses, fn a ->
      clean =
        a.analysis_text
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      snippet = String.slice(clean, 0, 150)
      suffix = if String.length(clean) > 150, do: "…", else: ""

      %{id: a.id, type: a.type, text: snippet <> suffix}
    end)
  end

  defp extract_text(raw) do
    get_in(raw, ["content", "text", "text"]) ||
      get_in(raw, ["content", "caption", "text"]) ||
      ""
  end

  @doc false
  def sender_labels(messages, session_id), do: sender_label_map(messages, session_id)

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
    cache_key = {:bot_context_user_label, session_id, sender_id}

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
    cache_key = {:bot_context_sender_chat_label, session_id, sender_id}

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

  defp build_chat_context(chat_id, messages, session_id, sender_labels)
       when is_integer(chat_id) and is_list(messages) and is_map(sender_labels) do
    chat_name = chat_name(chat_id, session_id)
    sender_ids = ordered_sender_ids(messages)
    shown = Enum.take(sender_ids, 80)
    extra_count = max(length(sender_ids) - length(shown), 0)

    participants =
      Enum.map(shown, fn sender_id ->
        %{
          id: sender_id,
          label: Map.get(sender_labels, sender_id, "user:#{sender_id}")
        }
      end)

    %{
      chat_id: chat_id,
      chat_name: chat_name,
      participants: participants,
      omitted_count: extra_count
    }
  end

  defp chat_name(chat_id, session_id) when is_integer(chat_id) do
    cache_key = {:bot_context_chat_name, session_id, chat_id}

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

  @doc false
  def default_telegram_session_id do
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

  # ── shared helpers ─────────────────────────────────────────────────

  defp message_unix(%{"date" => value}) when is_integer(value), do: value

  defp message_unix(%{"date" => value}) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp message_unix(_), do: nil

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, &to_int_or_fallback(&1["id"]))
  end

  defp to_int_or_fallback(value) when is_integer(value), do: value

  defp to_int_or_fallback(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_int_or_fallback(_), do: 0

  defp load_cycle_api_messages(cycle_id) do
    head_id = Agent.latest_head_id(%Cycle{id: cycle_id})

    head_id
    |> Agent.load_messages()
    |> Enum.map(&Message.to_api/1)
  end

  @doc false
  def extract_session_entries(api_messages) when is_list(api_messages) do
    Enum.flat_map(api_messages, fn
      %{"role" => "assistant", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_use", "name" => "send_message"} ->
            []

          %{"type" => "tool_use", "name" => name, "input" => input} ->
            [%{kind: :call, tool: name, input_json: encode_tool_input_json(input)}]

          _ ->
            []
        end)

      %{"role" => "user", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_result", "content" => result_content, "tool_use_id" => _id} ->
            result_text = tool_result_recap_text(result_content)

            if String.trim(result_text) == "sent" do
              []
            else
              [%{kind: :return, text: String.slice(result_text, 0, 500)}]
            end

          _ ->
            []
        end)

      _ ->
        []
    end)
  end

  def extract_session_entries(_), do: []

  defp encode_tool_input_json(input) do
    case Jason.encode(input) do
      {:ok, json} ->
        json

      _ ->
        inspect(input, limit: 50, printable_limit: 600)
    end
  end

  defp tool_result_recap_text(content) when is_binary(content), do: content

  defp tool_result_recap_text(content) when is_list(content) do
    Enum.map_join(content, "\n", &tool_result_block_text/1)
  end

  defp tool_result_recap_text(content),
    do: inspect(content, limit: 50, printable_limit: 2000)

  defp tool_result_block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"type" => type}) when is_binary(type), do: "[#{type}]"
  defp tool_result_block_text(other), do: inspect(other, limit: 20, printable_limit: 300)

  defp initial_context_opts(msg, bot_config) do
    case message_unix(msg) do
      unix when is_integer(unix) ->
        [before_unix: unix, telegram_session_id: bot_config.session_id, bot_id: bot_config.id]

      _ ->
        [telegram_session_id: bot_config.session_id, bot_id: bot_config.id]
    end
  end

  defp context_bot_id(opts) when is_list(opts) do
    case opts[:bot_id] do
      bot_id when is_binary(bot_id) and bot_id != "" ->
        bot_id

      _ ->
        nil
    end
  end

  defp append_response_instruction(parts) when is_list(parts) do
    case Enum.reverse(parts) do
      [] ->
        [String.trim(@response_instruction)]

      [last | rest] ->
        Enum.reverse([last <> @response_instruction | rest])
    end
  end

  defp to_text_blocks(parts) when is_list(parts) do
    Enum.map(parts, fn part ->
      %{"type" => "text", "text" => part}
    end)
  end
end
