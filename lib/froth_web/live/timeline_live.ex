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
  alias Froth.Telegram.Charlie
  alias Froth.Telegram.Message, as: TMsg
  alias Froth.Telegram.Names
  alias Froth.Telegram.Queries
  alias Froth.Telegram.Usernames

  alias FrothWeb.RemixLive, as: Remix

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
     |> load_chat()}
  end

  @impl true
  def handle_event("filter", %{"sender" => sender}, socket) do
    next =
      case Integer.parse(sender) do
        {id, ""} -> if socket.assigns.filter_sender == id, do: nil, else: id
        _ -> nil
      end

    {:noreply, assign(socket, :filter_sender, next)}
  end

  def handle_event("reload", _, socket), do: {:noreply, load_chat(socket)}

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
    short_names = Usernames.short_name_map(sender_ids)
    chat_title = Names.chat_name(chat_id, session_id)

    participants = participants(messages, short_names)

    reply_lookup =
      Map.new(messages, fn m ->
        {m.message_id,
         %{text: TMsg.text(m.raw), name: short_name_for(m.sender_id, short_names)}}
      end)

    cycles = load_cycle_traces(chat_id, messages, short_names)

    turns =
      build_timeline(messages, short_names, reply_lookup, cycles, chat_id)

    socket
    |> assign(:chat_title, chat_title)
    |> assign(:participants, participants)
    |> assign(:turns, turns)
    |> assign(:message_count, length(messages))
    |> assign(:oldest_date, List.first(messages) |> date_of())
    |> assign(:newest_date, List.last(messages) |> date_of())
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
      Map.merge(p, %{name: short_name_for(id, short_names), color: color_for(id)})
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
      Queries.cycle_traces_for_messages(chat_id, message_ids, bot_id: "charlie")

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
        bot_name: short_name_for(bot_sender_id, short_names) |> or_else("bot"),
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
        {dt, m.message_id, build_message_turn(m, short_names, reply_lookup, chat_id, dt)}
      end)

    cycle_entries =
      cycles
      |> Enum.map(fn cycle ->
        dt = shift_to_zone(cycle.inserted_at, tz)
        {dt, {:c, cycle.cycle_id}, build_cycle_turn(cycle, dt)}
      end)

    sorted =
      (message_entries ++ cycle_entries)
      |> Enum.sort_by(fn {dt, order, _} -> {DateTime.to_unix(dt, :microsecond), order} end)

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
    raw_text = TMsg.text(m.raw)
    text = raw_text || media_placeholder(m.raw)
    reply_id = TMsg.reply_to_message_id(m.raw)
    sender_id = m.sender_id || 0

    body =
      cond do
        raw_text -> parse_body(text)
        photo?(m.raw) -> {:photo, "/froth/media/#{chat_id}/#{m.message_id}", caption(m.raw)}
        true -> :media
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
       reply: reply_lookup[reply_id]
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

  # ─────────────────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="flex h-screen bg-void text-fg font-sans text-[13px] leading-5 antialiased">
        <.sidebar
          chat_title={@chat_title}
          chat_id={@chat_id}
          participants={@participants}
          filter_sender={@filter_sender}
          message_count={@message_count}
        />

        <main class="flex-1 flex flex-col min-w-0">
          <div
            id="timeline-scroll"
            phx-hook=".ScrollBottom"
            class="flex-1 overflow-y-auto"
          >
            <div class="max-w-[960px] mx-auto py-4 md:py-6">
              <%= for block <- @turns do %>
                <.timeline_block
                  block={block}
                  filter_sender={@filter_sender}
                />
              <% end %>
            </div>
          </div>
        </main>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
        export default {
          mounted() { this.el.scrollTop = this.el.scrollHeight; },
          updated() { this.el.scrollTop = this.el.scrollHeight; },
        };
      </script>
    </Layouts.app>
    """
  end

  # ─── Sidebar ──────────────────────────────────────────────────────────────

  defp sidebar(assigns) do
    ~H"""
    <aside class="w-[260px] shrink-0 border-r border-line bg-void hidden md:flex flex-col h-screen">
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
        <div class="font-mono text-2xs text-fg-mute mt-1 tabular-nums">{@chat_id}</div>
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
      <span class={["w-2 h-2 shrink-0 translate-y-[1px]", @color |> String.replace("text-", "bg-")]}>
      </span>
      <span class={["flex-1 min-w-0 truncate", @color]} title={@name}>{@name}</span>
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
        dimmed?: assigns.filter_sender != nil and assigns.filter_sender != turn.sender_id
      )

    ~H"""
    <div class={["transition-opacity", @dimmed? && "opacity-25"]}>
      <Remix.turn
        name={@turn.name}
        color={@turn.color}
        time={@turn.time}
        block?={block_turn?(@turn)}
      >
        <.reply_quote :if={@turn.reply} reply={@turn.reply} />
        <.message_body turn={@turn} />
      </Remix.turn>
    </div>
    """
  end

  defp timeline_block(%{block: {:cycle, cycle}} = assigns) do
    assigns = assign(assigns, :cycle, cycle)

    ~H"""
    <Remix.turn name={@cycle.name} color={@cycle.color} time={@cycle.time} block?={true}>
      <.cycle_trace cycle={@cycle} />
    </Remix.turn>
    """
  end

  defp block_turn?(turn) do
    turn.reply != nil or multi_paragraph?(turn) or photo_body?(turn)
  end

  defp multi_paragraph?(%{body: paragraphs}) when is_list(paragraphs), do: length(paragraphs) > 1
  defp multi_paragraph?(_), do: false

  defp photo_body?(%{body: {:photo, _, _}}), do: true
  defp photo_body?(_), do: false

  defp message_body(%{turn: %{body: :media, media_text: text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <span class="text-fg-mute italic">{@text}</span>
    """
  end

  defp message_body(%{turn: %{body: {:photo, url, caption}}} = assigns) do
    assigns = assign(assigns, url: url, caption: caption)

    ~H"""
    <div class="flex flex-col gap-1">
      <img
        src={@url}
        loading="lazy"
        class="max-w-[420px] max-h-[360px] object-contain border border-line"
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
    <code class="font-mono text-[12px] text-peach bg-amber/10 px-1">{elem(@seg, 1)}</code>
    """
  end

  # ─── Agent cycle (tool calls) ─────────────────────────────────────────────

  # Max lines rendered per output block before truncation.
  @output_max_lines 12
  @output_max_chars 900

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
            row = Map.put(pending || %{kind: :call, tool: "?"}, :result, entry.outcome)
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
        tool_label: tool_display(entry[:tool] || "?"),
        narration: entry[:narration],
        input: entry[:input] || %{},
        result: summarize_result(entry[:result]),
        output: render_output(entry[:result])
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-baseline gap-2 text-2xs text-fg-mute">
        <span class="text-peach font-medium">{@tool_label}</span>
        <span :if={@narration} class="truncate min-w-0" title={@narration}>· {@narration}</span>
        <span
          :if={@result && @result.label != "ok"}
          class={["ml-auto shrink-0 font-mono tabular-nums", @result.color]}
          title={@result.tooltip}
        >{@result.label}</span>
      </div>

      <.tool_input tool={@tool} input={@input} />
      <.tool_output output={@output} />
    </div>
    """
  end

  # Humanised tool names. Underscores become spaces so `run_shell`
  # reads as "run shell"; a few special cases are shortened.
  defp tool_display("run_shell"), do: "shell"
  defp tool_display("task_output"), do: "tail"
  defp tool_display("list_tasks"), do: "tasks"
  defp tool_display("elixir_eval"), do: "elixir"
  defp tool_display("send_message"), do: "reply"

  defp tool_display(tool) when is_binary(tool),
    do: String.replace(tool, "_", " ")

  defp tool_display(_), do: "?"

  # ─── Tool input rendering ──────────────────────────────────────────────

  defp tool_input(%{tool: "run_shell", input: %{"command" => cmd}} = assigns) when is_binary(cmd) do
    assigns = assign(assigns, :cmd, cmd)

    ~H"""
    <div class="font-mono text-[12px] leading-5 text-fg flex items-baseline gap-2 min-w-0">
      <span class="text-green select-none shrink-0">$</span>
      <span class="min-w-0 whitespace-pre-wrap break-all">{@cmd}</span>
    </div>
    """
  end

  defp tool_input(%{tool: "fetch", input: %{"source" => src}} = assigns) when is_binary(src) do
    assigns = assign(assigns, :src, src)

    ~H"""
    <div class="font-mono text-[12px] text-fg flex items-baseline gap-2 min-w-0">
      <span class="text-green select-none shrink-0">GET</span>
      <span class="truncate" title={@src}>{@src}</span>
    </div>
    """
  end

  defp tool_input(%{tool: "pager", input: input} = assigns) when map_size(input) > 0 do
    assigns = assign(assigns, :fields, pager_summary(input))

    ~H"""
    <div :if={@fields != ""} class="font-mono text-[12px] text-fg truncate">
      <span class="text-green select-none">pager</span>
      <span class="text-fg-mute"> {@fields}</span>
    </div>
    """
  end

  defp tool_input(%{tool: "task_output", input: %{"task_id" => id} = input} = assigns)
       when is_binary(id) do
    assigns =
      assign(assigns,
        id: id,
        lines: Map.get(input, "lines")
      )

    ~H"""
    <div class="font-mono text-[12px] text-fg flex items-baseline gap-2">
      <span class="text-green select-none">tail</span>
      <span>{@id}</span>
      <span :if={@lines} class="text-fg-ghost">· last {@lines}</span>
    </div>
    """
  end

  # Fallback: render the first scalar input field, if any, as `key=value`.
  defp tool_input(assigns) do
    summary = input_summary(assigns[:input] || %{})
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div :if={@summary != nil} class="font-mono text-[12px] text-fg-dim truncate" title={@summary}>
      {@summary}
    </div>
    """
  end

  defp pager_summary(input) do
    pairs =
      input
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect_compact(v)}" end)
      |> Enum.sort()

    Enum.join(pairs, " ")
  end

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

  defp inspect_compact(v) when is_binary(v), do: inspect(v, printable_limit: 40)
  defp inspect_compact(v), do: inspect(v, limit: 3, printable_limit: 40)

  # ─── Tool output rendering ─────────────────────────────────────────────

  # `render_output` normalises any outcome into either `nil` (nothing to show)
  # or a map with:
  #   :body — a preformatted string (possibly truncated), or nil
  #   :kind — "shell" / "error" / "await" / nil (used for colour)
  #   :footer — optional list of small kv pairs ("exit 0", "12 lines")
  #   :truncated? — bool
  defp render_output({:ok, [%{__struct__: Froth.Context.Block} = block | rest]}) do
    attrs = Map.get(block, :attrs, []) |> List.wrap()
    body = Map.get(block, :body) || ""
    {truncated_body, truncated?} = truncate_body(body)

    footer =
      [
        kv_footer(attrs, :exit_code, &"exit #{&1}"),
        kv_footer(attrs, :lines, &"#{&1} line#{if &1 == 1, do: "", else: "s"}"),
        kv_footer(attrs, :size, &format_size/1),
        if(rest != [], do: "+#{length(rest)} more block#{if length(rest) == 1, do: "", else: "s"}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    kind = Keyword.get(attrs, :kind)
    %{body: truncated_body, kind: kind, footer: footer, truncated?: truncated?}
  end

  defp render_output({:ok, value}) when is_binary(value) do
    {body, truncated?} = truncate_body(value)
    %{body: body, kind: nil, footer: [], truncated?: truncated?}
  end

  defp render_output({:ok, value}) when is_map(value) do
    inspected = inspect(value, limit: 6, printable_limit: 400, pretty: true)
    {body, truncated?} = truncate_body(inspected)
    %{body: body, kind: nil, footer: [], truncated?: truncated?}
  end

  defp render_output({:error, message}) do
    {body, truncated?} = truncate_body(to_string(message))
    %{body: body, kind: "error", footer: [], truncated?: truncated?}
  end

  defp render_output(_), do: nil

  defp kv_footer(attrs, key, fun) do
    case Keyword.get(attrs, key) do
      nil -> nil
      value -> fun.(value)
    end
  end

  defp truncate_body(body) when is_binary(body) do
    trimmed = String.trim_trailing(body)
    lines = String.split(trimmed, "\n")

    cond do
      length(lines) > @output_max_lines ->
        kept = Enum.take(lines, @output_max_lines) |> Enum.join("\n")
        {kept <> "\n… (" <> "#{length(lines) - @output_max_lines} more lines" <> ")", true}

      byte_size(trimmed) > @output_max_chars ->
        {String.slice(trimmed, 0, @output_max_chars) <> "…", true}

      true ->
        {trimmed, false}
    end
  end

  defp format_size(n) when is_integer(n) and n >= 1024,
    do: :io_lib.format("~.1fk", [n / 1024]) |> IO.iodata_to_binary()

  defp format_size(n) when is_integer(n), do: "#{n}b"
  defp format_size(_), do: nil

  defp tool_output(%{output: nil} = assigns), do: ~H""

  defp tool_output(%{output: %{body: body}} = assigns) when body in [nil, "", "nil"],
    do: ~H""

  defp tool_output(assigns) do
    ~H"""
    <div class="flex flex-col">
      <pre class={[
        "font-mono text-[12px] leading-5 border border-line px-2 py-1 overflow-x-auto whitespace-pre-wrap break-words max-h-[240px] overflow-y-auto",
        output_bg(@output.kind),
        output_color(@output.kind)
      ]}>{@output.body}</pre>
      <div
        :if={@output.footer != [] or @output.truncated?}
        class="flex items-baseline gap-2 text-2xs text-fg-ghost font-mono tabular-nums px-1 pt-0.5"
      >
        <span :for={item <- @output.footer}>{item}</span>
        <span :if={@output.truncated?} class="text-fg-mute">· truncated</span>
      </div>
    </div>
    """
  end

  defp output_bg("shell"), do: "bg-glow"
  defp output_bg("error"), do: "bg-red/10"
  defp output_bg(_), do: "bg-glow"

  defp output_color("error"), do: "text-red"
  defp output_color(_), do: "text-fg-dim"

  defp summarize_result(nil), do: nil

  defp summarize_result({:ok, _}), do: %{label: "ok", color: "text-green", tooltip: nil}

  defp summarize_result({:error, message}),
    do: %{label: "error", color: "text-red", tooltip: to_string(message)}

  defp summarize_result({:await, _}), do: %{label: "await", color: "text-amber", tooltip: nil}
  defp summarize_result({:yield, _}), do: %{label: "yield", color: "text-amber", tooltip: nil}

  defp summarize_result({:intervention, data}) do
    %{label: "intervention", color: "text-red", tooltip: inspect(data) |> String.slice(0, 160)}
  end

  defp summarize_result(_), do: nil


  defp reply_quote(assigns) do
    assigns =
      assign(assigns,
        name: assigns.reply.name,
        snippet: snippet(assigns.reply.text)
      )

    ~H"""
    <div class="mb-1 border-l-2 border-cyan/40 pl-3 py-0.5 flex flex-col gap-0.5">
      <span class="text-cyan font-sans text-2xs">↳ {@name}</span>
      <span :if={@snippet} class="font-mono text-2xs text-fg-mute truncate">{@snippet}</span>
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
