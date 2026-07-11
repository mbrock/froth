defmodule FrothWeb.TimelineLive do
  @moduledoc """
  A read-only timeline of a Telegram chat, rendered with the Froth-Remix
  design system. Defaults to Charlie's group chat; override with
  `?chat_id=…` in the URL.

  Reuses the function components exposed by `FrothWeb.RemixLive`
  (`turn`, `msg`, `daybreak`, `composer`, `side_row`) — this file is
  just a view-model + sidebar + event wiring.
  """
  use FrothWeb, :live_view

  alias Froth.Agent
  alias Froth.Context.Block
  alias Froth.Telegram
  alias Froth.Telegram.Charlie
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.Message, as: TMsg
  alias Froth.Telegram.Names
  alias Froth.Telegram.Queries
  alias Froth.Telegram.Usernames

  alias FrothWeb.RemixLive, as: Remix
  alias FrothWeb.SyntaxHighlight

  # Charlie's group-chat by default. Override with `?chat_id=…` on the URL.
  @default_chat_id -1_003_690_254_489
  @default_limit 600
  @default_lookback_days 60

  # Rotating palette used to colour sender names in the gutter. Same
  # tokens as the remix mockup so Berkeley Mono / amber / cyan / etc.
  # just work.
  @palette ~w(
    text-amber text-cyan text-violet text-pink text-green text-peach
    text-blue text-magenta text-lavender
  )

  # ─────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ─────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(params, _session, socket) do
    session_id = Charlie.default_config().session_id
    chat_id = parse_chat_id(params["chat_id"]) || @default_chat_id

    {:ok,
     socket
     |> assign(:page_title, "froth · timeline")
     |> assign(:session_id, session_id)
     |> assign(:chat_id, chat_id)
     |> assign(:filter_sender, nil)
     |> assign(:messages, [])
     |> assign(:short_names, %{})
     |> assign(:reply_lookup, %{})
     |> assign(:blocks, [])
     |> assign(:participants, [])
     |> assign(:chat_title, nil)
     |> assign(:message_count, 0)
     |> assign(:oldest_date, nil)
     |> assign(:newest_date, nil)
     |> assign(:latest_sort_key, nil)
     |> assign(:latest_day_key, nil)
     |> assign(:cycle_inserted_at, %{})
     |> assign(:syntax_highlight_css, SyntaxHighlight.stylesheet())
     |> assign(:chat_topic, nil)
     |> assign(:cycle_topics, MapSet.new())
     |> stream_configure(:blocks, dom_id: & &1.id)
     |> stream(:blocks, [], reset: true)
     |> load_chat()}
  end

  @impl true
  def handle_event("filter", %{"sender" => sender}, socket) do
    next =
      case Integer.parse(sender) do
        {id, ""} -> if socket.assigns.filter_sender == id, do: nil, else: id
        _ -> nil
      end

    {:noreply, socket |> assign(:filter_sender, next) |> sync_blocks()}
  end

  def handle_event("reload", _, socket), do: {:noreply, load_chat(socket)}

  @impl true
  def handle_info(
        {:message_persisted, chat_id, %TMsg{} = message},
        %{assigns: %{chat_id: chat_id}} = socket
      ) do
    {:noreply, append_message_block(socket, message)}
  end

  def handle_info(
        {:cycle_linked, chat_id, %CycleLink{bot_id: "charlie"} = cycle_link},
        %{assigns: %{chat_id: chat_id}} = socket
      ) do
    socket =
      socket
      |> track_cycle_link(cycle_link)
      |> refresh_cycle_block(cycle_link.cycle_id)

    {:noreply, socket}
  end

  # Every cycle event lands here now that Agent.append_event broadcasts
  # uniformly. We only re-render when a kind that could change the
  # rendered trace arrives — otherwise the cycle card is still accurate
  # and a full cycle_traces reload would just burn a query for no
  # visible change.
  def handle_info({:event, event}, socket) do
    cycle_id = event.metadata["cycle_id"]
    kind = event.metadata["kind"]

    cond do
      not is_binary(cycle_id) ->
        {:noreply, socket}

      not MapSet.member?(socket.assigns.cycle_topics, cycle_id) ->
        {:noreply, socket}

      cycle_event_affects_render?(kind) ->
        {:noreply, refresh_cycle_block(socket, cycle_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp cycle_event_affects_render?(kind) do
    kind in [
      "message.appended",
      "tool.completed",
      "tool.failed",
      "tool.timed_out",
      "control.outcome"
    ]
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Data loading
  # ─────────────────────────────────────────────────────────────────────────

  defp load_chat(socket) do
    %{session_id: session_id, chat_id: chat_id} = socket.assigns

    now = System.os_time(:second)
    since = now - @default_lookback_days * 86_400

    messages =
      Queries.fetch_recent_messages(chat_id, since, :infinity, @default_limit)
      |> dedupe_by_message_id()

    # Warm the @handle / label cache (triggers TDLib lookups for missing ids)
    # and then read short (first-name-preferring) names straight from the
    # `telegram_usernames` table.
    _labels = Names.sender_label_map(messages, session_id)

    sender_ids = messages |> Enum.map(& &1.sender_id) |> Enum.uniq()
    forwarded_user_ids = forwarded_user_ids(messages)
    short_names = Usernames.short_name_map(sender_ids ++ forwarded_user_ids)
    chat_title = Names.chat_name(chat_id, session_id)

    participants = participants(messages, short_names)

    reply_lookup =
      Map.new(messages, fn m ->
        {m.message_id,
         %{
           text: TMsg.text(m.raw),
           name: short_name_for(m.sender_id, short_names)
         }}
      end)

    cycles = load_cycle_traces(chat_id, messages, short_names)

    blocks =
      build_timeline(messages, short_names, reply_lookup, cycles, chat_id)

    socket
    |> maybe_subscribe_chat(chat_id)
    |> sync_cycle_topics(Enum.map(cycles, & &1.cycle_id))
    |> assign(:chat_title, chat_title)
    |> assign(:messages, messages)
    |> assign(:short_names, short_names)
    |> assign(:reply_lookup, reply_lookup)
    |> assign(:blocks, blocks)
    |> assign(
      :cycle_inserted_at,
      Map.new(cycles, &{&1.cycle_id, &1.inserted_at})
    )
    |> assign(:participants, participants)
    |> assign(:message_count, length(messages))
    |> assign(:oldest_date, List.first(messages) |> date_of())
    |> assign(:newest_date, List.last(messages) |> date_of())
    |> assign(:latest_sort_key, latest_sort_key(messages, cycles))
    |> assign(:latest_day_key, latest_day_key(messages, cycles))
    |> sync_blocks()
  end

  defp dedupe_by_message_id(messages) do
    messages
    |> Enum.reduce({[], MapSet.new()}, fn m, {kept, seen} ->
      if MapSet.member?(seen, m.message_id),
        do: {kept, seen},
        else: {[m | kept], MapSet.put(seen, m.message_id)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp date_of(nil), do: nil
  defp date_of(%{date: unix}) when is_integer(unix), do: unix
  defp date_of(_), do: nil

  defp latest_sort_key(messages, cycles) do
    message_key =
      case List.last(messages) do
        %{date: unix} when is_integer(unix) -> unix * 1_000_000
        _ -> nil
      end

    cycle_key =
      cycles
      |> Enum.map(&sort_key(&1.inserted_at))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    Enum.max([message_key, cycle_key], fn -> nil end)
  end

  defp latest_day_key(messages, cycles) do
    case latest_sort_key(messages, cycles) do
      nil ->
        nil

      latest ->
        cond do
          cycles != [] and
              latest == Enum.max(Enum.map(cycles, &sort_key(&1.inserted_at))) ->
            cycles
            |> Enum.max_by(&sort_key(&1.inserted_at))
            |> Map.fetch!(:inserted_at)
            |> shift_to_zone("Europe/Riga")
            |> day_key()

          true ->
            messages
            |> List.last()
            |> case do
              %{date: unix} when is_integer(unix) ->
                datetime_in("Europe/Riga", unix) |> day_key()

              _ ->
                nil
            end
        end
    end
  end

  defp participants(messages, short_names) do
    messages
    |> Enum.reduce(%{}, fn m, acc ->
      case m.sender_id do
        nil ->
          acc

        id ->
          acc
          |> Map.update(id, %{sender_id: id, count: 1, last: m.date}, fn p ->
            %{p | count: p.count + 1, last: max(p.last, m.date)}
          end)
      end
    end)
    |> Enum.map(fn {id, p} ->
      Map.merge(p, %{
        name: short_name_for(id, short_names),
        color: color_for(id)
      })
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp short_name_for(nil, _), do: "unknown"

  defp short_name_for(id, short_names) when is_integer(id) do
    case Map.get(short_names, id) do
      name when is_binary(name) and name != "" -> name
      _ when id < 0 -> "chat:#{id}"
      _ -> "user:#{id}"
    end
  end

  # Load every distinct agent cycle triggered by the visible messages, flat,
  # each carrying `bot_id`, `reply_to`, entries, and — denormalised — a
  # display name / colour so the cycle can be rendered as its own turn.
  defp load_cycle_traces(chat_id, messages, short_names) do
    message_ids = Enum.map(messages, & &1.message_id)

    links_by_message =
      Queries.cycle_traces_for_messages(chat_id, message_ids,
        bot_id: "charlie"
      )

    links =
      links_by_message
      |> Enum.flat_map(fn {msg_id, ls} ->
        Enum.map(ls, fn l -> Map.put(l, :reply_to, msg_id) end)
      end)
      |> Enum.uniq_by(& &1.cycle_id)

    entries_by_cycle =
      case Enum.map(links, & &1.cycle_id) do
        [] -> %{}
        ids -> Agent.cycle_traces(ids)
      end

    links
    |> Enum.map(fn l ->
      entries = Map.get(entries_by_cycle, l.cycle_id, [])
      bot_sender_id = bot_sender_id("charlie", short_names, messages)

      %{
        cycle_id: l.cycle_id,
        reply_to: l.reply_to,
        inserted_at: l.inserted_at,
        entries: entries,
        bot_name:
          short_name_for(bot_sender_id, short_names) |> or_else("bot"),
        bot_color: color_for(bot_sender_id)
      }
    end)
    |> Enum.reject(&(&1.entries == []))
  end

  defp or_else(nil, fallback), do: fallback
  defp or_else("", fallback), do: fallback
  defp or_else(value, _), do: value

  # Look up the bot's sender_id. We rely on the telegram_usernames table
  # having a first_name that matches what we call the bot (for charlie,
  # "Charlie"). Falls back to any sender_id that maps to that name in the
  # visible messages.
  defp bot_sender_id("charlie", short_names, _messages) do
    short_names
    |> Enum.find(fn {_id, name} -> name == "Charlie" end)
    |> case do
      {id, _} -> id
      _ -> nil
    end
  end

  defp bot_sender_id(_, _, _), do: nil

  # ─────────────────────────────────────────────────────────────────────────
  # Turn construction
  # ─────────────────────────────────────────────────────────────────────────

  # Merge messages + cycles into one chronological stream, emitting
  # `{:daybreak, dt}` between calendar days.
  defp build_timeline(messages, short_names, reply_lookup, cycles, chat_id) do
    tz = "Europe/Riga"

    message_entries =
      messages
      |> Enum.map(fn m ->
        dt = datetime_in(tz, m.date)

        {dt, m.message_id,
         build_message_turn(m, short_names, reply_lookup, chat_id, dt)}
      end)

    cycle_entries =
      cycles
      |> Enum.map(fn cycle ->
        dt = shift_to_zone(cycle.inserted_at, tz)
        {dt, {:c, cycle.cycle_id}, build_cycle_turn(cycle, dt)}
      end)

    sorted =
      (message_entries ++ cycle_entries)
      |> Enum.sort_by(fn {dt, order, _} ->
        {DateTime.to_unix(dt, :microsecond), order}
      end)

    {blocks, _last_day} =
      Enum.reduce(sorted, {[], nil}, fn {dt, _order, turn}, {acc, last_day} ->
        day_key = Date.to_iso8601(DateTime.to_date(dt))

        acc =
          if last_day != day_key do
            [{:daybreak, dt} | acc]
          else
            acc
          end

        {[turn | acc], day_key}
      end)

    Enum.reverse(blocks)
  end

  defp build_message_turn(m, short_names, reply_lookup, chat_id, dt) do
    raw_text = m.raw |> TMsg.text() |> present_text()
    text = raw_text || media_placeholder(m.raw)
    reply_id = TMsg.reply_to_message_id(m.raw)
    sender_id = m.sender_id || 0
    forward = forward_attribution(m.raw, short_names)

    body =
      cond do
        raw_text ->
          parse_body(text)

        photo?(m.raw) ->
          {width, height} = photo_dimensions(m.raw)

          {:photo, "/froth/media/#{chat_id}/#{m.message_id}", caption(m.raw),
           width, height}

        true ->
          :media
      end

    {:turn,
     %{
       id: "m-#{m.message_id}",
       sender_id: sender_id,
       name: short_name_for(sender_id, short_names),
       color: color_for(sender_id),
       time: format_time(dt),
       body: body,
       media_text: text,
       reply: reply_lookup[reply_id],
       forward: forward
     }}
  end

  defp build_cycle_turn(cycle, dt) do
    {:cycle,
     %{
       id: "c-#{cycle.cycle_id}",
       cycle_id: cycle.cycle_id,
       name: cycle.bot_name,
       color: cycle.bot_color,
       time: format_time(dt),
       entries: summarize_cycle(cycle.entries)
     }}
  end

  defp photo?(%{"content" => %{"@type" => "messagePhoto"}}), do: true
  defp photo?(_), do: false

  defp caption(raw) do
    case get_in(raw, ["content", "caption", "text"]) do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  defp photo_dimensions(raw) do
    raw
    |> get_in(["content", "photo", "sizes"])
    |> List.wrap()
    |> Enum.max_by(
      fn size -> (size["width"] || 0) * (size["height"] || 0) end,
      fn -> %{} end
    )
    |> then(&{&1["width"], &1["height"]})
  end

  defp present_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end

  defp present_text(_), do: nil

  # Turn raw message text into a list of paragraphs.
  #
  #   - Trim leading/trailing whitespace on the whole message.
  #   - Split on runs of blank lines (`\n\s*\n+`) → paragraphs.
  #   - Inside each paragraph, single `\n`s are collapsed to spaces so
  #     the browser can word-wrap cleanly against the container.
  #   - Within the collapsed text, split on backticks → alternating
  #     `{:text, _}` / `{:code, _}` segments. Unmatched backticks stay
  #     as literal text.
  defp parse_body(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.split(~r/\n\s*\n+/)
    |> Enum.map(&paragraph_segments/1)
    |> Enum.reject(&(&1 == []))
  end

  defp paragraph_segments(paragraph) do
    paragraph
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.trim()
    |> segment_by_backticks()
  end

  defp segment_by_backticks(""), do: []

  defp segment_by_backticks(text) do
    parts = String.split(text, "`")

    case rem(length(parts), 2) do
      # Unmatched backtick — keep the raw text.
      0 ->
        [{:text, text}]

      _ ->
        parts
        |> Enum.with_index()
        |> Enum.map(fn
          {chunk, idx} when rem(idx, 2) == 0 -> {:text, chunk}
          {chunk, _} -> {:code, chunk}
        end)
        |> Enum.reject(fn {_, v} -> v == "" end)
    end
  end

  defp media_placeholder(raw) do
    case get_in(raw, ["content", "@type"]) do
      "messagePhoto" -> "(photo)"
      "messageVideo" -> "(video)"
      "messageAnimation" -> "(gif)"
      "messageAudio" -> "(audio)"
      "messageVoiceNote" -> "(voice note)"
      "messageVideoNote" -> "(video note)"
      "messageDocument" -> "(document)"
      "messageSticker" -> "(sticker)"
      "messageLocation" -> "(location)"
      "messageContact" -> "(contact)"
      "messagePoll" -> "(poll)"
      nil -> "(non-text message)"
      other -> "(" <> String.replace_prefix(other, "message", "") <> ")"
    end
  end

  defp color_for(sender_id) when is_integer(sender_id) do
    Enum.at(@palette, rem(abs(sender_id), length(@palette)))
  end

  defp color_for(_), do: "text-fg-dim"

  defp datetime_in(tz, unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> shift_to_zone(tz)
  end

  defp shift_to_zone(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> shifted
      _ -> dt
    end
  end

  defp shift_to_zone(%NaiveDateTime{} = ndt, tz) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> shift_to_zone(tz)
  end

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M")

  defp sync_blocks(socket) do
    stream_items = Enum.map(socket.assigns.blocks, &timeline_stream_item/1)
    stream(socket, :blocks, stream_items, reset: true)
  end

  defp timeline_stream_item(block), do: %{id: block_id(block), block: block}

  defp block_id({:turn, %{id: id}}), do: id
  defp block_id({:cycle, %{id: id}}), do: id
  defp block_id({:daybreak, dt}), do: "d-#{day_key(dt)}"

  defp sort_key(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp sort_key(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> sort_key()

  defp sort_key(unix) when is_integer(unix), do: unix * 1_000_000
  defp sort_key(_), do: nil

  defp day_key(%DateTime{} = dt), do: Date.to_iso8601(DateTime.to_date(dt))

  defp day_key(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> day_key()

  defp maybe_subscribe_chat(socket, chat_id) when is_integer(chat_id) do
    topic = Telegram.chat_topic(chat_id)

    socket =
      if connected?(socket) do
        if is_binary(socket.assigns.chat_topic) and
             socket.assigns.chat_topic != topic do
          Phoenix.PubSub.unsubscribe(Froth.PubSub, socket.assigns.chat_topic)
        end

        if socket.assigns.chat_topic != topic do
          Phoenix.PubSub.subscribe(Froth.PubSub, topic)
        end

        socket
      else
        socket
      end

    assign(socket, :chat_topic, topic)
  end

  defp maybe_subscribe_chat(socket, _chat_id), do: socket

  defp sync_cycle_topics(socket, cycle_ids) do
    desired = cycle_ids |> Enum.filter(&is_binary/1) |> MapSet.new()
    current = socket.assigns.cycle_topics || MapSet.new()

    if connected?(socket) do
      MapSet.difference(current, desired)
      |> Enum.each(fn cycle_id ->
        Phoenix.PubSub.unsubscribe(Froth.PubSub, "cycle:#{cycle_id}")
      end)

      MapSet.difference(desired, current)
      |> Enum.each(fn cycle_id ->
        Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle_id}")
      end)
    end

    assign(socket, :cycle_topics, desired)
  end

  defp track_cycle_link(socket, %CycleLink{
         cycle_id: cycle_id,
         chat_id: chat_id,
         inserted_at: inserted_at
       })
       when is_binary(cycle_id) and is_integer(chat_id) do
    socket
    |> assign(
      :cycle_inserted_at,
      Map.put(socket.assigns.cycle_inserted_at, cycle_id, inserted_at)
    )
    |> sync_cycle_topics(
      MapSet.put(socket.assigns.cycle_topics, cycle_id)
      |> MapSet.to_list()
    )
  end

  defp append_message_block(socket, %TMsg{} = message) do
    dt = datetime_in("Europe/Riga", message.date)

    if out_of_order?(socket.assigns.latest_sort_key, dt) do
      load_chat(socket)
    else
      short_names =
        ensure_short_names(
          socket.assigns.short_names,
          socket.assigns.session_id,
          [message.sender_id | forwarded_user_ids([message])]
        )

      block =
        build_message_turn(
          message,
          short_names,
          socket.assigns.reply_lookup,
          socket.assigns.chat_id,
          dt
        )

      blocks_to_append =
        maybe_daybreak(socket.assigns.latest_day_key, dt) ++ [block]

      reply_lookup =
        Map.put(socket.assigns.reply_lookup, message.message_id, %{
          text: TMsg.text(message.raw),
          name: short_name_for(message.sender_id, short_names)
        })

      messages = socket.assigns.messages ++ [message]
      blocks = socket.assigns.blocks ++ blocks_to_append
      participants = participants(messages, short_names)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:short_names, short_names)
        |> assign(:reply_lookup, reply_lookup)
        |> assign(:blocks, blocks)
        |> assign(:participants, participants)
        |> assign(:message_count, length(messages))
        |> assign(:oldest_date, List.first(messages) |> date_of())
        |> assign(:newest_date, List.last(messages) |> date_of())
        |> assign(:latest_sort_key, sort_key(dt))
        |> assign(:latest_day_key, day_key(dt))

      Enum.reduce(blocks_to_append, socket, fn next_block, acc ->
        stream_insert(acc, :blocks, timeline_stream_item(next_block), at: -1)
      end)
    end
  end

  defp refresh_cycle_block(socket, cycle_id) when is_binary(cycle_id) do
    case Map.get(socket.assigns.cycle_inserted_at, cycle_id) do
      nil ->
        socket

      inserted_at ->
        entries =
          Agent.cycle_traces([cycle_id])
          |> Map.get(cycle_id, [])

        cond do
          entries == [] ->
            socket

          true ->
            dt = shift_to_zone(inserted_at, "Europe/Riga")

            if out_of_order_new_block?(socket, cycle_id, dt) do
              load_chat(socket)
            else
              cycle =
                %{
                  cycle_id: cycle_id,
                  inserted_at: inserted_at,
                  entries: entries,
                  bot_name: timeline_bot_name(socket.assigns.short_names),
                  bot_color: timeline_bot_color(socket.assigns.short_names)
                }

              block = build_cycle_turn(cycle, dt)

              case upsert_block(socket.assigns.blocks, block) do
                :insert ->
                  blocks_to_append =
                    maybe_daybreak(socket.assigns.latest_day_key, dt) ++
                      [block]

                  blocks = socket.assigns.blocks ++ blocks_to_append

                  socket =
                    socket
                    |> assign(:blocks, blocks)
                    |> assign(:latest_sort_key, sort_key(dt))
                    |> assign(:latest_day_key, day_key(dt))

                  Enum.reduce(blocks_to_append, socket, fn next_block, acc ->
                    stream_insert(
                      acc,
                      :blocks,
                      timeline_stream_item(next_block),
                      at: -1
                    )
                  end)

                {:update, blocks} ->
                  socket
                  |> assign(:blocks, blocks)
                  |> assign(
                    :latest_sort_key,
                    max_sort_key(socket.assigns.latest_sort_key, dt)
                  )
                  |> assign(
                    :latest_day_key,
                    max_day_key(socket.assigns.latest_day_key, dt)
                  )
                  |> stream_insert(:blocks, timeline_stream_item(block))
              end
            end
        end
    end
  end

  defp refresh_cycle_block(socket, _cycle_id), do: socket

  defp upsert_block(blocks, block) do
    id = block_id(block)

    case Enum.find_index(blocks, &(block_id(&1) == id)) do
      nil -> :insert
      idx -> {:update, List.replace_at(blocks, idx, block)}
    end
  end

  defp maybe_daybreak(nil, dt), do: [{:daybreak, dt}]

  defp maybe_daybreak(current_day_key, dt) do
    if current_day_key == day_key(dt), do: [], else: [{:daybreak, dt}]
  end

  defp ensure_short_names(short_names, session_id, sender_ids) do
    missing =
      sender_ids
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.reject(&Map.has_key?(short_names, &1))
      |> Enum.uniq()

    if missing == [] do
      short_names
    else
      _labels = Names.labels_for_ids(missing, session_id)
      Map.merge(short_names, Usernames.short_name_map(missing))
    end
  end

  defp timeline_bot_name(short_names) do
    case bot_sender_id(short_names, "charlie") do
      id when is_integer(id) -> short_name_for(id, short_names)
      _ -> "bot"
    end
  end

  defp timeline_bot_color(short_names) do
    short_names
    |> bot_sender_id("charlie")
    |> color_for()
  end

  defp bot_sender_id(short_names, "charlie") do
    short_names
    |> Enum.find(fn {_id, name} -> name == "Charlie" end)
    |> case do
      {id, _} -> id
      _ -> nil
    end
  end

  defp bot_sender_id(_short_names, _bot_id), do: nil

  defp out_of_order?(nil, _dt), do: false
  defp out_of_order?(latest_sort_key, dt), do: sort_key(dt) < latest_sort_key

  defp out_of_order_new_block?(socket, cycle_id, dt) do
    latest_sort_key = socket.assigns.latest_sort_key

    not cycle_block_present?(socket.assigns.blocks, cycle_id) and
      out_of_order?(latest_sort_key, dt)
  end

  defp cycle_block_present?(blocks, cycle_id) do
    Enum.any?(blocks, fn
      {:cycle, %{cycle_id: ^cycle_id}} -> true
      _ -> false
    end)
  end

  defp max_sort_key(nil, dt), do: sort_key(dt)

  defp max_sort_key(latest_sort_key, dt),
    do: max(latest_sort_key, sort_key(dt))

  defp max_day_key(nil, dt), do: day_key(dt)

  defp max_day_key(current_day_key, dt) do
    if current_day_key >= day_key(dt), do: current_day_key, else: day_key(dt)
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <style id="timeline-syntax-highlight">
        <%= Phoenix.HTML.raw(@syntax_highlight_css) %>
      </style>
      <div
        id="timeline-shell"
        class="app-shell safe-top flex h-dvh max-h-dvh min-h-0 overflow-hidden bg-void text-fg font-sans text-[13px] leading-5 antialiased"
      >
        <.sidebar
          chat_title={@chat_title}
          chat_id={@chat_id}
          participants={@participants}
          filter_sender={@filter_sender}
          message_count={@message_count}
        />

        <main
          id="timeline-live-viewer"
          phx-hook="ToolScroll"
          data-follow-mode="smart"
          class="flex-1 flex flex-col min-w-0 overflow-hidden"
        >
          <div
            id="timeline-scroll"
            data-scroll-body
            class="safe-bottom flex-1 overflow-y-auto overscroll-contain"
          >
            <div
              id="timeline-blocks"
              phx-update="stream"
              class="max-w-[960px] mx-auto py-4 md:py-6"
            >
              <div :for={{dom_id, item} <- @streams.blocks} id={dom_id}>
                <.timeline_block
                  block={item.block}
                  filter_sender={@filter_sender}
                />
              </div>
              <div id="timeline-feed-end" data-scroll-end></div>
            </div>
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end

  # ─── Sidebar ──────────────────────────────────────────────────────────────

  defp sidebar(assigns) do
    ~H"""
    <aside class="w-[260px] shrink-0 border-r border-line bg-void hidden h-full md:flex flex-col">
      <div class="px-4 py-4 flex items-baseline gap-2 border-b border-line">
        <span class="text-amber">❡</span>
        <span class="text-fg font-medium tracking-tight">froth</span>
        <span class="ml-auto text-2xs text-fg-mute">timeline</span>
      </div>

      <div class="px-4 py-3 border-b border-line">
        <div class="text-2xs text-fg-mute mb-0.5">chat</div>
        <div class="text-fg truncate" title={@chat_title}>
          <span class="text-amber">#</span>{@chat_title}
        </div>
        <div class="font-mono text-2xs text-fg-mute mt-1 tabular-nums">
          {@chat_id}
        </div>
      </div>

      <div class="py-2 overflow-y-auto flex-1">
        <div class="text-2xs text-fg-mute px-4 py-1.5 flex items-baseline gap-2">
          <span>participants</span>
          <span :if={@filter_sender} class="text-amber">· filtered</span>
        </div>

        <%= for p <- @participants do %>
          <.participant_row
            sender_id={p.sender_id}
            name={p.name}
            color={p.color}
            count={p.count}
            active?={@filter_sender == p.sender_id}
          />
        <% end %>
      </div>

      <div class="px-4 py-3 border-t border-line text-2xs">
        <div class="grid grid-cols-[64px_1fr] gap-2 gap-y-0.5">
          <span class="text-fg-ghost">messages</span>
          <span class="text-fg-dim">
            <span class="font-mono tabular-nums">{@message_count}</span>
          </span>
          <span class="text-fg-ghost">people</span>
          <span class="text-fg-dim">
            <span class="font-mono tabular-nums">{length(@participants)}</span>
          </span>
        </div>
      </div>
    </aside>
    """
  end

  defp participant_row(assigns) do
    ~H"""
    <div
      class={[
        "flex items-baseline gap-2 px-4 py-1 cursor-pointer transition-colors",
        if(@active?, do: "bg-amber/10", else: "hover:bg-glow")
      ]}
      phx-click="filter"
      phx-value-sender={@sender_id}
    >
      <span class={[
        "w-2 h-2 shrink-0 translate-y-[1px]",
        @color |> String.replace("text-", "bg-")
      ]}>
      </span>
      <span class={["flex-1 min-w-0 truncate", @color]} title={@name}>
        {@name}
      </span>
      <span class="font-mono text-2xs text-fg-ghost tabular-nums">{@count}</span>
    </div>
    """
  end

  # ─── Timeline blocks ──────────────────────────────────────────────────────

  defp timeline_block(%{block: {:daybreak, dt}} = assigns) do
    assigns =
      assign(assigns,
        weekday: Calendar.strftime(dt, "%a") |> String.downcase(),
        date: Calendar.strftime(dt, "%-d %B %Y") |> String.downcase()
      )

    ~H"""
    <Remix.daybreak weekday={@weekday} date={@date} />
    """
  end

  defp timeline_block(%{block: {:turn, turn}} = assigns) do
    assigns =
      assign(assigns,
        turn: turn,
        dimmed?:
          assigns.filter_sender != nil and
            assigns.filter_sender != turn.sender_id
      )

    ~H"""
    <div class={["transition-opacity", @dimmed? && "opacity-25"]}>
      <Remix.turn
        name={@turn.name}
        color={@turn.color}
        time={@turn.time}
        block?={block_turn?(@turn)}
      >
        <.forward_badge :if={@turn.forward} forward={@turn.forward} />
        <.reply_quote :if={@turn.reply} reply={@turn.reply} />
        <.message_body turn={@turn} />
      </Remix.turn>
    </div>
    """
  end

  defp timeline_block(%{block: {:cycle, cycle}} = assigns) do
    assigns = assign(assigns, :cycle, cycle)

    ~H"""
    <Remix.turn
      name={@cycle.name}
      color={@cycle.color}
      time={@cycle.time}
      block?={true}
    >
      <.cycle_trace cycle={@cycle} />
    </Remix.turn>
    """
  end

  defp block_turn?(turn) do
    turn.forward != nil or turn.reply != nil or multi_paragraph?(turn) or
      photo_body?(turn)
  end

  defp multi_paragraph?(%{body: paragraphs}) when is_list(paragraphs),
    do: length(paragraphs) > 1

  defp multi_paragraph?(_), do: false

  defp photo_body?(%{body: {:photo, _, _, _, _}}), do: true
  defp photo_body?(_), do: false

  defp message_body(%{turn: %{body: :media, media_text: text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <span class="text-fg-mute italic">{@text}</span>
    """
  end

  defp message_body(
         %{turn: %{body: {:photo, url, caption, width, height}}} = assigns
       ) do
    assigns =
      assign(assigns,
        url: url,
        caption: caption,
        width: width,
        height: height
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <img
        src={@url}
        loading="lazy"
        width={@width}
        height={@height}
        class="h-auto w-auto max-w-[420px] max-h-[360px] object-contain border border-line"
        alt="photo"
      />
      <p :if={@caption} class="text-fg-dim break-words">{@caption}</p>
    </div>
    """
  end

  defp message_body(%{turn: %{body: paragraphs}} = assigns) do
    assigns = assign(assigns, :paragraphs, paragraphs)

    ~H"""
    <div class="text-fg-dim break-words">
      <p :for={para <- @paragraphs} class="mt-2 first:mt-0">
        <%= for seg <- para do %>
          <.body_segment seg={seg} />
        <% end %>
      </p>
    </div>
    """
  end

  defp body_segment(%{seg: {:text, _}} = assigns) do
    ~H"{elem(@seg, 1)}"
  end

  defp body_segment(%{seg: {:code, _}} = assigns) do
    ~H"""
    <code class="font-mono text-[12px] text-peach bg-amber/10 px-1">
      {elem(@seg, 1)}
    </code>
    """
  end

  # ─── Agent cycle (tool calls) ─────────────────────────────────────────────

  defp cycle_trace(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <%= for entry <- @cycle.entries do %>
        <.cycle_entry entry={entry} />
      <% end %>
    </div>
    """
  end

  # Pair each :call with its :return or :intervention (if any), so the
  # UI shows one row per tool invocation. Skip `send_message` at the
  # data layer already (Agent.cycle_traces does that); we also merge
  # the result snippet into the call row for compactness.
  defp summarize_cycle(entries) do
    {rows, pending} =
      Enum.reduce(entries, {[], nil}, fn entry, {acc, pending} ->
        case entry.kind do
          :call ->
            acc = if pending, do: [pending | acc], else: acc
            {acc, entry}

          :return ->
            row =
              Map.put(
                pending || %{kind: :call, tool: "?"},
                :result,
                entry.outcome
              )

            {[row | acc], nil}

          :intervention ->
            row =
              Map.put(
                pending || %{kind: :call, tool: "?"},
                :result,
                {:intervention, entry[:text] || entry[:data]}
              )

            {[row | acc], nil}

          _ ->
            {acc, pending}
        end
      end)

    rows = if pending, do: [pending | rows], else: rows
    Enum.reverse(rows)
  end

  defp cycle_entry(%{entry: entry} = assigns) do
    assigns =
      assign(assigns,
        tool: entry[:tool] || "?",
        narration: entry[:narration],
        input: entry[:input] || %{},
        result: summarize_result(entry[:result]),
        output: render_output(entry[:tool] || "?", entry[:result])
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <div
        :if={@narration || (@result && @result.label != "ok")}
        class="flex items-baseline gap-2 text-2xs text-fg-mute"
      >
        <span :if={@narration} class="truncate min-w-0" title={@narration}>
          {@narration}
        </span>
        <span
          :if={@result && @result.label != "ok"}
          class={["ml-auto shrink-0 font-mono tabular-nums", @result.color]}
          title={@result.tooltip}
        >
          {@result.label}
        </span>
      </div>

      <.tool_input tool={@tool} input={@input} />
      <.tool_output output={@output} />
    </div>
    """
  end

  # ─── Tool input rendering ──────────────────────────────────────────────

  defp tool_input(%{tool: "run_shell", input: %{"command" => cmd}} = assigns)
       when is_binary(cmd) do
    assigns = assign(assigns, :cmd, cmd)

    ~H"""
    <div class="font-mono text-[12px] leading-5 text-fg flex items-baseline gap-2 min-w-0">
      <span class="text-green select-none shrink-0">$</span>
      <span class="min-w-0 whitespace-pre-wrap break-all">{@cmd}</span>
    </div>
    """
  end

  defp tool_input(
         %{tool: "elixir_eval", input: %{"code" => code} = input} = assigns
       )
       when is_binary(code) do
    assigns =
      assign(assigns,
        code_htmls: SyntaxHighlight.elixir_htmls(code),
        session_id: short_eval_session_id(input["session_id"])
      )

    ~H"""
    <div class="overflow-hidden border border-amber/20">
      <div class="flex items-baseline gap-2 border-b border-amber/20 px-2 py-1 font-mono text-2xs uppercase tracking-[0.14em]">
        <span class="text-amber">elixir</span>
        <span :if={@session_id} class="text-fg-ghost normal-case tracking-normal">
          session {@session_id}
        </span>
      </div>
      <div class="px-2 py-1">
        <.responsive_highlight htmls={@code_htmls} />
      </div>
    </div>
    """
  end

  defp tool_input(%{tool: "fetch", input: %{"source" => src}} = assigns)
       when is_binary(src) do
    assigns = assign(assigns, :src, src)

    ~H"""
    <div class="font-mono text-[12px] text-cyan truncate" title={@src}>
      {@src}
    </div>
    """
  end

  defp tool_input(%{tool: "pager", input: input} = assigns) do
    assigns = assign(assigns, :summary, pager_summary(input))

    ~H"""
    <div :if={@summary} class="font-mono text-[12px] text-fg-mute truncate">
      {@summary}
    </div>
    """
  end

  defp tool_input(
         %{tool: "task_output", input: %{"task_id" => id} = input} = assigns
       )
       when is_binary(id) do
    assigns =
      assign(assigns,
        id: id,
        lines: Map.get(input, "lines")
      )

    ~H"""
    <div class="font-mono text-[12px] text-fg-mute flex items-baseline gap-2">
      <span class="text-fg">{@id}</span>
      <span :if={@lines}>· last {@lines}</span>
    </div>
    """
  end

  # Fallback: render the first scalar input field, if any, as `key=value`.
  defp tool_input(assigns) do
    summary = input_summary(assigns[:input] || %{})
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div
      :if={@summary != nil}
      class="font-mono text-[12px] text-fg-dim truncate"
      title={@summary}
    >
      {@summary}
    </div>
    """
  end

  # Reduce pager input to the only two things worth glancing at: the
  # line window it's scrolled to (if any) and any active pattern filter.
  # The `id` / `mode` are noise for humans.
  defp pager_summary(input) do
    from = input["from_line"]
    n = input["lines"]
    pattern = input["pattern"]
    max = input["max"]

    [
      pager_range(from, n),
      pattern && "match " <> inspect(pattern),
      max && "max #{max}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp pager_range(nil, nil), do: nil
  defp pager_range(nil, n) when is_integer(n), do: "first #{n} lines"

  defp pager_range(from, nil) when is_integer(from), do: "from line #{from}"

  defp pager_range(from, n) when is_integer(from) and is_integer(n),
    do: "lines #{from}–#{from + n - 1}"

  defp pager_range(_, _), do: nil

  defp input_summary(input) when map_size(input) == 0, do: nil

  defp input_summary(input) do
    input
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.find_value(fn {k, v} ->
      case v do
        s when is_binary(s) and s != "" -> "#{k}=#{String.slice(s, 0, 120)}"
        n when is_number(n) -> "#{k}=#{n}"
        true -> "#{k}=true"
        false -> "#{k}=false"
        _ -> nil
      end
    end)
  end

  # ─── Tool output rendering ─────────────────────────────────────────────

  # Normalise any outcome into either `nil` (nothing to show) or
  # `%{body, kind, footer}`. No text-level truncation — the scroll
  # box in `tool_output/1` clips visually instead.
  defp render_output("elixir_eval", {:ok, [%Block{} | _] = blocks}) do
    session_id =
      blocks
      |> Enum.find_value(&Block.attr(&1, :session))
      |> short_eval_session_id()

    sections =
      blocks
      |> Enum.map(&eval_output_section/1)
      |> Enum.reject(&is_nil/1)
      |> attach_eval_session(session_id)

    if sections == [], do: nil, else: %{variant: :eval, sections: sections}
  end

  defp render_output(_tool, {:ok, [%Block{} = block | rest]}) do
    attrs = Map.get(block, :attrs, []) |> List.wrap()
    body = Map.get(block, :body) |> normalize_body()

    footer =
      [
        kv_footer(attrs, :exit_code, &"exit #{&1}"),
        kv_footer(
          attrs,
          :lines,
          &"#{&1} line#{if &1 == 1, do: "", else: "s"}"
        ),
        kv_footer(attrs, :size, &format_size/1),
        if(rest != [],
          do:
            "+#{length(rest)} more block#{if length(rest) == 1, do: "", else: "s"}",
          else: nil
        )
      ]
      |> Enum.reject(&is_nil/1)

    %{body: body, kind: Keyword.get(attrs, :kind), footer: footer}
  end

  defp render_output(_tool, {:ok, value}) when is_binary(value) do
    %{body: normalize_body(value), kind: nil, footer: []}
  end

  defp render_output(_tool, {:ok, value}) when is_map(value) do
    %{
      body: inspect(value, limit: 10, printable_limit: 1000, pretty: true),
      kind: nil,
      footer: []
    }
  end

  defp render_output(_tool, {:error, message}) do
    %{body: to_string(message), kind: "error", footer: []}
  end

  defp render_output(_tool, _), do: nil

  defp eval_output_section(%Block{} = block) do
    body = normalize_body(block.body)
    kind = Block.attr(block, :kind)

    meta =
      [
        Block.attr(block, :lines)
        |> case do
          n when is_integer(n) -> "#{n} line#{if n == 1, do: "", else: "s"}"
          _ -> nil
        end,
        Block.attr(block, :size) |> format_size()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
      |> case do
        "" -> nil
        text -> text
      end

    case body do
      "" ->
        nil

      _ ->
        %{
          kind: kind,
          label: eval_output_label(kind),
          htmls: eval_output_htmls(kind, body),
          body: body,
          meta: meta,
          session_id: nil
        }
    end
  end

  defp attach_eval_session([], _session_id), do: []

  defp attach_eval_session([first | rest], session_id) do
    [%{first | session_id: session_id} | rest]
  end

  defp eval_output_label("value"), do: "result"
  defp eval_output_label("io"), do: "io"
  defp eval_output_label("error"), do: "error"

  defp eval_output_label(kind) when is_binary(kind) and kind != "",
    do: String.replace(kind, "_", " ")

  defp eval_output_label(_), do: "output"

  defp eval_output_htmls("value", body),
    do: SyntaxHighlight.elixir_htmls(body)

  defp eval_output_htmls(_kind, _body), do: nil

  defp normalize_body(nil), do: ""

  defp normalize_body(body) when is_binary(body),
    do: String.trim_trailing(body)

  defp kv_footer(attrs, key, fun) do
    case Keyword.get(attrs, key) do
      nil -> nil
      value -> fun.(value)
    end
  end

  defp format_size(n) when is_integer(n) and n >= 1024,
    do: :io_lib.format("~.1fk", [n / 1024]) |> IO.iodata_to_binary()

  defp format_size(n) when is_integer(n), do: "#{n}b"
  defp format_size(_), do: nil

  defp tool_output(%{output: nil} = assigns), do: ~H""

  defp tool_output(%{output: %{body: body}} = assigns)
       when body in [nil, "", "nil"],
       do: ~H""

  defp tool_output(%{output: %{variant: :eval, sections: sections}} = assigns)
       when sections == [] do
    ~H""
  end

  defp tool_output(%{output: %{variant: :eval}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div
        :for={section <- @output.sections}
        class={eval_output_frame_class(section.kind)}
      >
        <div class="flex items-baseline gap-2 border-b border-current/20 px-2 py-1 font-mono text-2xs uppercase tracking-[0.14em]">
          <span class={eval_output_label_class(section.kind)}>
            {section.label}
          </span>
          <span
            :if={section.session_id}
            class="text-fg-ghost normal-case tracking-normal"
          >
            session {section.session_id}
          </span>
          <span
            :if={section.meta}
            class="ml-auto text-fg-ghost normal-case tracking-normal"
          >
            {section.meta}
          </span>
        </div>

        <div :if={section.htmls} class="px-2 py-1">
          <.responsive_highlight htmls={section.htmls} />
        </div>

        <pre
          :if={!section.htmls}
          class={[
            "max-h-[280px] overflow-auto whitespace-pre px-2 py-1.5 font-mono text-[12px] leading-5",
            eval_output_text_class(section.kind)
          ]}
        >{section.body}</pre>
      </div>
    </div>
    """
  end

  defp tool_output(assigns) do
    ~H"""
    <div class="flex flex-col">
      <pre class={[
        "font-mono text-[12px] leading-5 border border-line px-2 py-1 overflow-auto whitespace-pre max-h-[280px]",
        output_bg(@output.kind),
        output_color(@output.kind)
      ]}>{@output.body}</pre>
      <div
        :if={@output.footer != []}
        class="flex items-baseline gap-2 text-2xs text-fg-ghost font-mono tabular-nums px-1 pt-0.5"
      >
        <span :for={item <- @output.footer}>{item}</span>
      </div>
    </div>
    """
  end

  attr :htmls, :map, required: true

  defp responsive_highlight(assigns) do
    ~H"""
    <div class="hidden text-fg md:block">
      {raw(@htmls.desktop_html)}
    </div>
    <div class="text-fg md:hidden">
      {raw(@htmls.mobile_html)}
    </div>
    """
  end

  defp output_bg("shell"), do: "bg-glow"
  defp output_bg("error"), do: "bg-red/10"
  defp output_bg(_), do: "bg-glow"

  defp output_color("error"), do: "text-red"
  defp output_color(_), do: "text-fg-dim"

  defp eval_output_frame_class("value"),
    do: "overflow-hidden border border-amber/20"

  defp eval_output_frame_class("io"),
    do: "overflow-hidden border border-cyan/20"

  defp eval_output_frame_class("error"),
    do: "overflow-hidden border border-red/20"

  defp eval_output_frame_class(_), do: "overflow-hidden border border-line"

  defp eval_output_label_class("value"), do: "text-amber"
  defp eval_output_label_class("io"), do: "text-cyan"
  defp eval_output_label_class("error"), do: "text-red"
  defp eval_output_label_class(_), do: "text-fg"

  defp eval_output_text_class("error"), do: "text-red"
  defp eval_output_text_class(_), do: "text-fg-dim"

  defp short_eval_session_id(nil), do: nil

  defp short_eval_session_id(session_id) when is_binary(session_id) do
    trimmed = String.replace_prefix(session_id, "eval_session_", "")

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > 12 -> String.slice(trimmed, 0, 12) <> "…"
      true -> trimmed
    end
  end

  defp summarize_result(nil), do: nil

  defp summarize_result({:ok, _}),
    do: %{label: "ok", color: "text-green", tooltip: nil}

  defp summarize_result({:error, message}),
    do: %{label: "error", color: "text-red", tooltip: to_string(message)}

  defp summarize_result({:await, _}),
    do: %{label: "await", color: "text-amber", tooltip: nil}

  defp summarize_result({:yield, _}),
    do: %{label: "yield", color: "text-amber", tooltip: nil}

  defp summarize_result({:intervention, data}) do
    %{
      label: "intervention",
      color: "text-red",
      tooltip: inspect(data) |> String.slice(0, 160)
    }
  end

  defp summarize_result(_), do: nil

  # ---------------------------------------------------------------------------
  # Forward attribution
  # ---------------------------------------------------------------------------

  defp forwarded_user_ids(messages) do
    messages
    |> Enum.map(fn m -> TMsg.forward_info(m.raw) end)
    |> Enum.flat_map(fn
      %{kind: :user, user_id: uid} when is_integer(uid) -> [uid]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp forward_attribution(raw, short_names) do
    case TMsg.forward_info(raw) do
      nil ->
        nil

      %{kind: :user, user_id: uid} ->
        %{label: short_name_for(uid, short_names), origin: "user"}

      %{kind: :hidden, name: name} ->
        %{label: present_name(name), origin: "hidden"}

      %{kind: :chat, signature: sig} ->
        %{label: present_name(sig) || "a chat", origin: "chat"}

      %{kind: :channel, signature: sig} ->
        %{label: present_name(sig) || "a channel", origin: "channel"}
    end
  end

  defp present_name(name) when is_binary(name) and name != "", do: name
  defp present_name(_), do: nil

  defp forward_badge(assigns) do
    ~H"""
    <div class="mb-1 border-l-2 border-fg-mute/40 pl-3 py-0.5">
      <span class="text-fg-mute font-sans text-2xs italic">
        ⤴ forwarded from {@forward.label}
      </span>
    </div>
    """
  end

  defp reply_quote(assigns) do
    assigns =
      assign(assigns,
        name: assigns.reply.name,
        snippet: snippet(assigns.reply.text)
      )

    ~H"""
    <div class="mb-1 border-l-2 border-cyan/40 pl-3 py-0.5 flex flex-col gap-0.5">
      <span class="text-cyan font-sans text-2xs">↳ {@name}</span>
      <span :if={@snippet} class="font-mono text-2xs text-fg-mute truncate">
        {@snippet}
      </span>
    </div>
    """
  end

  defp snippet(nil), do: nil

  defp snippet(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 120)
  end

  defp parse_chat_id(nil), do: nil

  defp parse_chat_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
