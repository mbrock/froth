defmodule FrothWeb.RemixLive do
  @moduledoc """
  A Phoenix LiveView rendering of the `priv/froth_remix/` design mockup
  (the Latvian-tax-invoice / luna-dd scenario).

  This file is intentionally self-contained:

    * the **view model** (room, people, artifacts, turns) lives in module
      attributes / pure functions at the bottom;
    * a handful of inline **function components** render it;
    * minimal server-side **interaction state** (open drawer, podcast play
      position, hot-lineage hover) lives in assigns.

  The design tokens used by the Tailwind classes below (`bg-void`,
  `text-fg-mute`, `border-line`, `text-amber`, `text-2xs`, `animate-blink`,
  etc.) are defined in `assets/css/app.css` under the `@theme` block labelled
  "Froth Remix design tokens".
  """
  use FrothWeb, :live_view

  # ─────────────────────────────────────────────────────────────────────────
  # LiveView lifecycle
  # ─────────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "froth · luna-dd")
     |> assign(:room, room())
     |> assign(:drawer_key, nil)
     |> assign(:paid?, true)
     |> assign(:playing?, false)
     |> assign(:play_pos, 0.33)}
  end

  @impl true
  def handle_event("open_drawer", %{"key" => key}, socket),
    do: {:noreply, assign(socket, :drawer_key, key)}

  def handle_event("close_drawer", _, socket),
    do: {:noreply, assign(socket, :drawer_key, nil)}

  def handle_event("toggle_play", _, socket),
    do: {:noreply, assign(socket, :playing?, not socket.assigns.playing?)}

  # ─────────────────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lineage_set, lineage_for(assigns.drawer_key))

    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="flex h-screen bg-void text-fg font-sans text-[13px] leading-5 antialiased">
        <.sidebar room={@room} active={@drawer_key} />

        <main class="flex-1 flex flex-col min-w-0">
          <div class="flex-1 overflow-y-auto">
            <div class="max-w-[960px] mx-auto py-6">
              <.daybreak
                weekday={@room.date_label.weekday}
                date={@room.date_label.date}
                range={@room.range}
              />

              <%= for turn <- @room.turns do %>
                <.turn
                  name={@room.people[turn.who].name}
                  color={@room.people[turn.who].color}
                  time={turn.time}
                  block?={turn.block?}
                  threaded?={turn.threaded?}
                  is_child?={turn.is_child?}
                  hot?={MapSet.member?(@lineage_set, turn.id)}
                >
                  <%= for block <- turn.body do %>
                    <.turn_block
                      block={block}
                      paid?={@paid?}
                      playing?={@playing?}
                      play_pos={@play_pos}
                    />
                  <% end %>
                </.turn>
              <% end %>
            </div>
          </div>

          <.composer />
        </main>

        <.drawer artifact={@drawer_key && @room.artifacts[@drawer_key]} />
      </div>
    </Layouts.app>
    """
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Function components
  # ─────────────────────────────────────────────────────────────────────────

  defp sidebar(assigns) do
    ~H"""
    <aside class="w-[260px] shrink-0 border-r border-line bg-void flex flex-col h-screen">
      <div class="px-4 py-4 flex items-baseline gap-2 border-b border-line">
        <span class="text-amber">❡</span>
        <span class="text-fg font-medium tracking-tight">froth</span>
        <span class="ml-auto text-2xs text-fg-mute">{@room.me}</span>
      </div>

      <div class="px-4 py-3 border-b border-line">
        <div class="text-2xs text-fg-mute mb-0.5">room</div>
        <div class="text-fg">
          <span class="text-amber">#</span>{@room.slug}
        </div>
        <div class="text-2xs text-fg-mute mt-1">{@room.members_label}</div>
      </div>

      <div class="py-2 overflow-y-auto flex-1">
        <div class="text-2xs text-fg-mute px-4 py-1.5">artifacts · today</div>
        <%= for item <- @room.sidebar_artifacts do %>
          <.side_row
            glyph={item.glyph}
            name={item.name}
            meta={item.meta}
            active?={@active == item.key}
            click="open_drawer"
            value_key={item.key}
          />
        <% end %>
      </div>

      <div class="px-4 py-3 border-t border-line text-2xs">
        <div class="grid grid-cols-[64px_1fr] gap-2 gap-y-0.5">
          <span class="text-fg-ghost">status</span>
          <span class="text-green">● {@room.status}</span>
          <span class="text-fg-ghost">agents</span>
          <span class="text-fg-dim">
            <span class="font-mono">{@room.agents_online}</span> online
          </span>
          <span class="text-fg-ghost">room age</span>
          <span class="text-fg-dim">
            <span class="font-mono">{@room.age}</span>
          </span>
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  A sidebar row — glyph, name, optional meta, optional `phx-click`.
  Reusable outside the remix mockup: see `FrothWeb.TimelineLive` for a
  stripped-down usage.
  """
  attr :glyph, :string, default: " "
  attr :name, :string, required: true
  attr :meta, :string, default: nil
  attr :active?, :boolean, default: false
  attr :click, :string, default: nil
  attr :value_key, :string, default: nil

  def side_row(assigns) do
    ~H"""
    <div
      class={[
        "flex items-baseline gap-2 px-4 py-1.5 transition-colors",
        @click && "cursor-pointer",
        if(@active?, do: "bg-amber/10 text-fg", else: "hover:bg-glow text-fg-dim")
      ]}
      phx-click={@click}
      phx-value-key={@value_key}
    >
      <span class="w-4 text-center text-fg-mute">{@glyph}</span>
      <span class="flex-1 min-w-0 truncate">{@name}</span>
      <span :if={@meta} class="text-2xs text-fg-ghost">{@meta}</span>
    </div>
    """
  end

  @doc """
  The day-break header that sits above the transcript — weekday, date, range.
  """
  attr :weekday, :string, required: true
  attr :date, :string, required: true
  attr :range, :string, default: nil

  def daybreak(assigns) do
    ~H"""
    <div class="grid grid-cols-[56px_1fr_56px] gap-x-4 px-7 py-2 items-baseline">
      <div class="text-right text-fg-mute text-2xs">{@weekday}</div>
      <div class="text-fg-mute text-2xs">
        {@date}
        <span :if={@range} class="font-mono text-fg-ghost ml-3 tabular-nums">
          {@range}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  One visual row in a transcript. `inner_block` is the message body —
  plain text, a `.msg`, an artifact, whatever the caller wants.
  """
  attr :name, :string, required: true
  attr :color, :string, default: "text-fg"
  attr :time, :string, default: ""
  attr :block?, :boolean, default: false
  attr :threaded?, :boolean, default: false
  attr :is_child?, :boolean, default: false
  attr :hot?, :boolean, default: false
  slot :inner_block, required: true

  def turn(assigns) do
    ~H"""
    <div class={[
      "relative px-4 md:grid md:grid-cols-[56px_1fr_56px] md:gap-x-4 md:px-7",
      if(@block?, do: "py-1.5", else: "py-0.5")
    ]}>
      <div class="mb-1 flex items-baseline justify-between gap-3 md:hidden">
        <span
          class={[
            "font-sans font-medium tracking-tight inline-block max-w-full min-w-0 align-baseline truncate",
            @color
          ]}
          title={@name}
        >
          {@name}
        </span>
        <span class="shrink-0 font-mono text-2xs text-fg-ghost tabular-nums">
          {@time}
        </span>
      </div>

      <div class="relative hidden text-right md:block md:col-start-1 md:row-start-1">
        <span
          class={[
            "font-sans font-medium tracking-tight inline-block max-w-full align-baseline truncate",
            @color
          ]}
          title={@name}
        >
          {@name}
        </span>
        <span
          :if={@threaded? and @hot?}
          class="absolute left-[calc(100%+8px)] top-5 bottom-0 w-px bg-cyan shadow-[0_0_6px_-1px_rgba(75,212,227,0.7)]"
        />
        <span
          :if={@threaded? and not @hot?}
          class="absolute left-[calc(100%+8px)] top-5 bottom-0 w-px bg-line"
        />
        <span
          :if={@is_child? and @hot?}
          class="absolute left-[calc(100%+6px)] top-2.5 w-2 h-2 -translate-x-1/2 bg-cyan shadow-[0_0_6px_-1px_rgba(75,212,227,0.7)]"
        />
        <span
          :if={@is_child? and not @hot?}
          class="absolute left-[calc(100%+6px)] top-2.5 w-2 h-2 -translate-x-1/2 bg-cyan/40"
        />
      </div>

      <div class="min-w-0 md:col-start-2 md:row-start-1">
        {render_slot(@inner_block)}
      </div>

      <div class="hidden font-mono text-2xs text-fg-ghost tabular-nums text-right pt-[2px] md:block md:col-start-3 md:row-start-1">
        {@time}
      </div>
    </div>
    """
  end

  # Each block inside a turn: inline message, an artifact, a quoted reply, …
  # Remix-specific; only used by `RemixLive` below.
  defp turn_block(%{block: {:msg, _}} = assigns) do
    ~H"""
    <span class="text-fg-dim"><.msg parts={elem(@block, 1)} /></span>
    """
  end

  defp turn_block(%{block: {:artifact, key, attrs}} = assigns) do
    assigns = assign(assigns, key: key, artifact: Map.new(attrs))

    ~H"""
    <div class="my-1.5">
      <div class="cursor-pointer" phx-click="open_drawer" phx-value-key={@key}>
        <.artifact_body
          artifact={@artifact}
          paid?={@paid?}
          playing?={@playing?}
          play_pos={@play_pos}
        />
      </div>
      <.artifact_footer artifact={@artifact} />
    </div>
    """
  end

  defp turn_block(%{block: {:quote, attrs}} = assigns) do
    assigns = assign(assigns, q: Map.new(attrs))

    ~H"""
    <div class="mt-1 border-l-2 border-cyan/40 pl-3 py-1 flex flex-col gap-1">
      <span
        class="text-cyan font-sans text-2xs cursor-pointer hover:underline"
        phx-click="open_drawer"
        phx-value-key={@q.source}
      >
        ↳ {@q.label}
      </span>
      <span class="font-mono text-2xs text-fg-mute">{@q.body}</span>
    </div>
    """
  end

  @doc """
  Inline text with lightweight tagged-segment markup, so the view-model
  stays pure data:

      [
        "hey, ",
        {:mention, "@orr"},
        " — see ",
        {:tag, "swedbank · operating"},
        "?"
      ]

  Supported segments: plain binary, `{:mute, s}`, `{:mention, s}`,
  `{:tag, s}`, `{:emoji, s}`, `{:raw, html}`.
  """
  attr :parts, :list, required: true

  def msg(assigns) do
    ~H"""
    <%= for part <- @parts do %>
      <.msg_part part={part} />
    <% end %>
    """
  end

  defp msg_part(%{part: text} = assigns) when is_binary(text) do
    ~H"""
    {@part}
    """
  end

  defp msg_part(%{part: {:mute, _}} = assigns) do
    ~H"""
    <span class="text-fg-mute">{elem(@part, 1)}</span>
    """
  end

  defp msg_part(%{part: {:mention, _}} = assigns) do
    ~H"""
    <span class="text-cyan cursor-pointer hover:underline">{elem(@part, 1)}</span>
    """
  end

  defp msg_part(%{part: {:tag, _}} = assigns) do
    ~H"""
    <span class="font-mono text-2xs text-amber bg-amber/10 px-1">
      {elem(@part, 1)}
    </span>
    """
  end

  defp msg_part(%{part: {:emoji, _}} = assigns) do
    ~H"""
    <span class="align-[-1px] text-base">{elem(@part, 1)}</span>
    """
  end

  defp msg_part(%{part: {:raw, _}} = assigns) do
    ~H"""
    {Phoenix.HTML.raw(elem(@part, 1))}
    """
  end

  defp artifact_footer(assigns) do
    ~H"""
    <div
      :if={@artifact[:caption] || @artifact[:lineage] not in [nil, []]}
      class="mt-1.5 flex flex-wrap items-baseline gap-x-3 gap-y-0.5 font-sans text-2xs text-fg-mute"
    >
      <span :if={@artifact[:caption]}>{@artifact[:caption]}</span>
      <%= for line <- @artifact[:lineage] || [] do %>
        <span
          class={[
            "inline-flex items-baseline gap-1",
            line[:link] && "cursor-pointer hover:text-cyan"
          ]}
          phx-click={line[:link] && "open_drawer"}
          phx-value-key={line[:link]}
        >
          <span class="text-fg-ghost">↳</span>{line.label}
        </span>
      <% end %>
    </div>
    """
  end

  # ─── Artifact bodies ─────────────────────────────────────────────────────

  defp artifact_body(%{artifact: %{kind: :image}} = assigns) do
    ~H"""
    <div class="inline-block overflow-hidden bg-void" style="width: 280px">
      <svg viewBox="0 0 400 290" width="100%" preserveAspectRatio="xMidYMid slice">
        <defs>
          <radialGradient id="invoice-glow" cx="46%" cy="52%" r="62%">
            <stop offset="0%" stop-color="#e8a33d" stop-opacity="0.42" />
            <stop offset="50%" stop-color="#7a5423" stop-opacity="0.2" />
            <stop offset="100%" stop-color="#000" stop-opacity="0" />
          </radialGradient>
          <pattern
            id="invoice-paper"
            width="3"
            height="5"
            patternUnits="userSpaceOnUse"
          >
            <path
              d="M0 5 L3 5"
              stroke="#2a2218"
              stroke-width="0.25"
              opacity="0.5"
            />
          </pattern>
        </defs>
        <rect width="400" height="290" fill="#070609" />
        <g transform="rotate(-3 200 145)">
          <rect
            x="70"
            y="28"
            width="260"
            height="234"
            fill="#1c150c"
            stroke="#3a2d1c"
            stroke-width="0.6"
          />
          <rect x="70" y="28" width="260" height="234" fill="url(#invoice-paper)" />
          <g font-family="monospace" fill="#78726a">
            <text x="84" y="52" font-size="6.5" letter-spacing="0.4">
              VALSTS IEŅĒMUMU DIENESTS
            </text>
            <text x="84" y="63" font-size="5" opacity="0.6">
              Talejas iela 1, Rīga LV-1978
            </text>
            <text x="84" y="88" font-size="6">RĒĶINS</text>
            <text x="130" y="88" font-size="6" fill="#a8a49a">2026-00412</text>
            <text x="84" y="110" font-size="5.5">soc. apdrošināšana</text>
            <text x="280" y="110" font-size="5.5" text-anchor="end">863.00</text>
            <text x="84" y="120" font-size="5.5">procenti (12 d.)</text>
            <text x="280" y="120" font-size="5.5" text-anchor="end">12.40</text>
            <line
              x1="84"
              y1="128"
              x2="280"
              y2="128"
              stroke="#3a2d1c"
              stroke-width="0.4"
            />
            <text x="84" y="140" font-size="7" fill="#c9c3b5">KOPĀ</text>
            <text x="280" y="140" font-size="7" fill="#e8a33d" text-anchor="end">
              875.40 EUR
            </text>
            <text x="84" y="170" font-size="5">termiņš  2026-04-20</text>
            <text x="84" y="180" font-size="5">maksātājs  Mira Ozola</text>
            <text x="84" y="220" font-size="4.5" opacity="0.5">
              LV40003456789 · IBAN LV08 HABA …
            </text>
          </g>
        </g>
        <rect width="400" height="290" fill="url(#invoice-glow)" />
      </svg>
    </div>
    """
  end

  defp artifact_body(%{artifact: %{kind: :ledger}} = assigns) do
    ~H"""
    <div class="inline-block border border-line bg-raised p-4 min-w-[360px] max-w-[480px]">
      <div class="flex items-baseline gap-4 pb-3 border-b border-line">
        <div class="flex-1 min-w-0">
          <div class="text-fg">{@artifact.payer}</div>
          <div class="font-mono text-2xs text-fg-mute tabular-nums mt-0.5">
            {@artifact.ref}
          </div>
        </div>
        <div class="text-right">
          <div class="font-sans text-2xs text-fg-mute">EUR</div>
          <div class="font-mono text-xl leading-none text-fg tabular-nums mt-1">
            {@artifact.amount}
          </div>
        </div>
      </div>

      <dl class="grid grid-cols-[80px_1fr] gap-x-4 gap-y-1 pt-3 text-[13px]">
        <dt class="text-fg-mute text-2xs self-center">issued</dt>
        <dd class="m-0 font-mono tabular-nums text-fg-dim">{@artifact.issued}</dd>
        <dt class="text-fg-mute text-2xs self-center">due</dt>
        <dd class="m-0 text-fg-dim">
          <span class="font-mono tabular-nums">{@artifact.due}</span>
        </dd>
        <dt class="text-fg-mute text-2xs self-center">debit</dt>
        <dd class="m-0 text-fg-dim">{@artifact.debit}</dd>
      </dl>

      <%= if @paid? do %>
        <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1 mt-4 pt-3 border-t border-dashed border-line text-2xs">
          <span class="text-green">● signed</span>
          <span class="text-green">broadcast</span>
          <span class="text-green">confirmed</span>
          <span class="text-fg-ghost">·</span>
          <span class="text-fg-mute">
            tx <span class="font-mono text-fg-dim">{@artifact.tx_hash}</span>
          </span>
          <span class="text-fg-ghost">·</span>
          <span class="text-fg-mute">
            settled <span class="font-mono">{@artifact.settled_at}</span>
          </span>
        </div>
      <% else %>
        <div class="flex items-baseline gap-3 mt-4 pt-3 border-t border-line">
          <button class="bg-amber text-void px-3 h-8 font-sans font-medium text-[13px] hover:brightness-110 transition">
            authorize &nbsp;·&nbsp; {@artifact.amount} EUR &nbsp;→
          </button>
          <span class="text-2xs text-fg-mute">SEPA · touch-id on phone</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp artifact_body(%{artifact: %{kind: :shell}} = assigns) do
    ~H"""
    <div class="font-mono text-[13px] max-w-[720px]">
      <%= for line <- @artifact.lines do %>
        <div class="grid grid-cols-[16px_1fr_auto] gap-2 items-baseline">
          <span class={["font-bold", shell_glyph_color(line)]}>
            {shell_glyph(line)}
          </span>
          <span class={shell_text_color(line)}>
            {line.text}
            <span
              :if={line[:live?]}
              class="inline-block w-[7px] h-3 bg-amber align-[-2px] ml-0.5 animate-blink"
            />
          </span>
          <span class="text-fg-ghost text-2xs tabular-nums">
            {line[:ms] || ""}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  defp artifact_body(%{artifact: %{kind: :code}} = assigns) do
    ~H"""
    <div class="border border-line bg-raised max-w-[720px]">
      <div class="flex items-baseline gap-4 px-3 py-1.5 border-b border-line font-mono text-2xs">
        <span class="text-fg">{@artifact.path}</span>
        <span class="ml-auto">
          <span class="text-green">+{@artifact.added}</span>
          <span class="text-fg-ghost mx-1">/</span>
          <span class="text-red">−{@artifact.deleted}</span>
        </span>
      </div>

      <div class="font-mono text-2xs py-1">
        <%= for line <- @artifact.lines do %>
          <div class={[
            "grid grid-cols-[32px_32px_16px_1fr] px-2",
            diff_row_bg(line.kind)
          ]}>
            <span class="text-fg-ghost tabular-nums text-right pr-2">
              {line[:a] || ""}
            </span>
            <span class="text-fg-ghost tabular-nums text-right pr-2">
              {line[:b] || ""}
            </span>
            <span class={[diff_marker_color(line.kind), "text-center"]}>
              {diff_marker(line.kind)}
            </span>
            <span class="text-fg-dim">{Phoenix.HTML.raw(line.src)}</span>
          </div>
        <% end %>
      </div>

      <div
        :if={@artifact[:review]}
        class="px-3 py-2 border-t border-line text-2xs text-fg-dim"
      >
        <span class="text-cyan font-medium mr-2">{@artifact.review.by}</span>
        {Phoenix.HTML.raw(@artifact.review.html)}
      </div>
    </div>
    """
  end

  defp artifact_body(%{artifact: %{kind: :audio}} = assigns) do
    assigns =
      assign(assigns,
        cur_idx: floor(assigns.play_pos * length(assigns.artifact.waveform)),
        cur_seconds:
          floor(assigns.play_pos * assigns.artifact.duration_seconds),
        mm_ss: mm_ss(assigns.play_pos, assigns.artifact.duration_seconds)
      )

    ~H"""
    <div class="inline-flex items-center gap-3 border border-line bg-raised pl-2 pr-3 py-2 max-w-[620px]">
      <button
        type="button"
        phx-click="toggle_play"
        class="w-7 h-7 flex items-center justify-center bg-green text-void font-mono text-xs hover:brightness-110 transition"
      >
        {if @playing?, do: "❚❚", else: "▶"}
      </button>
      <div class="text-fg-dim text-[13px] min-w-0 max-w-[280px] truncate">
        {@artifact.title}
      </div>
      <div class="flex items-end gap-[2px] h-5">
        <%= for {h, i} <- Enum.with_index(@artifact.waveform) do %>
          <div
            class={[
              "w-[2px] transition-colors",
              cond do
                i / length(@artifact.waveform) < @play_pos -> "bg-green"
                i == @cur_idx -> "bg-green shadow-[0_0_6px_-1px_#5ae38a]"
                true -> "bg-line"
              end
            ]}
            style={"height: #{trunc(2 + h * 14)}px"}
          />
        <% end %>
      </div>
      <div class="font-mono text-2xs tabular-nums text-fg-dim whitespace-nowrap">
        {@mm_ss}<span class="text-fg-ghost"> / {@artifact.duration_label}</span>
      </div>
    </div>
    """
  end

  # ─── Drawer ───────────────────────────────────────────────────────────────

  defp drawer(assigns) do
    ~H"""
    <div
      class={[
        "fixed inset-0 bg-void/70 z-40 transition-opacity",
        if(@artifact,
          do: "opacity-100 pointer-events-auto",
          else: "opacity-0 pointer-events-none"
        )
      ]}
      phx-click="close_drawer"
    />
    <aside class={[
      "fixed top-0 right-0 bottom-0 w-[600px] z-50 bg-void border-l border-line overflow-y-auto",
      "transition-transform duration-200",
      if(@artifact, do: "translate-x-0", else: "translate-x-full")
    ]}>
      <%= if @artifact do %>
        <div class="sticky top-0 bg-void border-b border-line px-6 py-4 flex items-baseline gap-3">
          <span class="text-2xs text-fg-mute">{@artifact.kind_label}</span>
          <span class="font-medium text-fg tracking-tight flex-1 min-w-0 truncate">
            {@artifact.name}
          </span>
          <button
            type="button"
            class="text-fg-mute hover:text-fg px-1 font-sans"
            phx-click="close_drawer"
          >
            close ✕
          </button>
        </div>

        <div class="px-6 py-4 border-b border-line">
          <dl class="grid grid-cols-[100px_1fr] gap-x-4 gap-y-1 text-[13px]">
            <dt class="text-fg-mute text-2xs">id</dt>
            <dd class="m-0 text-fg font-mono text-2xs">{@artifact.id}</dd>
            <dt class="text-fg-mute text-2xs">version</dt>
            <dd class="m-0 text-fg">{@artifact.version}</dd>
            <dt class="text-fg-mute text-2xs">by</dt>
            <dd class="m-0 text-fg">{@artifact.by}</dd>
            <dt class="text-fg-mute text-2xs">created</dt>
            <dd class="m-0 text-fg font-mono text-2xs tabular-nums">
              {@artifact.created}
            </dd>
          </dl>
        </div>

        <div class="px-6 py-4 border-b border-line">
          <h4 class="font-sans text-2xs text-fg-mute mb-2 flex items-baseline gap-2">
            <span>provenance</span>
            <span class="text-fg-ghost font-normal">
              · upstream {length(@artifact.ancestors)}, downstream {length(
                @artifact.descendants
              )}
            </span>
          </h4>
          <div class="text-[13px]">
            <%= for {a, i} <- Enum.with_index(@artifact.ancestors) do %>
              <div
                class="flex items-baseline gap-2 py-1"
                style={"padding-left: #{i * 20}px"}
              >
                <span class="text-fg-ghost font-mono text-2xs">└</span>
                <span class="text-fg-mute text-2xs">{a.kind}</span>
                <span class="text-fg font-medium">{a.name}</span>
                <span class="text-fg-mute text-2xs ml-auto">{a.by}</span>
              </div>
            <% end %>
            <div
              class="flex items-baseline gap-2 py-1 border-l-2 border-amber bg-amber/10 pl-2"
              style={"margin-left: #{length(@artifact.ancestors) * 20}px"}
            >
              <span class="text-amber font-mono text-2xs">●</span>
              <span class="text-amber text-2xs">{@artifact.kind_label}</span>
              <span class="text-fg font-medium">{@artifact.name}</span>
              <span class="text-fg-mute text-2xs ml-auto">(this)</span>
            </div>
            <%= for {d, i} <- Enum.with_index(@artifact.descendants) do %>
              <div
                class="flex items-baseline gap-2 py-1"
                style={"padding-left: #{(length(@artifact.ancestors) + 1 + i) * 20}px"}
              >
                <span class="text-fg-ghost font-mono text-2xs">└</span>
                <span class="text-fg-mute text-2xs">{d.kind}</span>
                <span class="text-fg font-medium">{d.name}</span>
                <span class="text-fg-mute text-2xs ml-auto">{d.by}</span>
              </div>
            <% end %>
            <div
              :if={@artifact.descendants == []}
              class="text-fg-ghost text-2xs py-1"
              style={"margin-left: #{(length(@artifact.ancestors) + 1) * 20}px"}
            >
              — no descendants yet —
            </div>
          </div>
        </div>

        <div class="px-6 py-4 border-b border-line">
          <h4 class="font-sans text-2xs text-fg-mute mb-2 flex items-baseline gap-2">
            <span>history</span>
            <span class="text-fg-ghost font-normal">
              · {length(@artifact.history)} entries
            </span>
          </h4>
          <div class="space-y-0.5">
            <%= for h <- @artifact.history do %>
              <div class="grid grid-cols-[72px_56px_1fr_auto] gap-3 text-[13px]">
                <span class="font-mono text-2xs text-lavender tabular-nums">
                  {h.when}
                </span>
                <span class={["text-2xs", history_op_color(h.op)]}>{h.op}</span>
                <span class="text-fg-dim">{h.what}</span>
                <span class="text-fg-mute text-2xs">{h.by}</span>
              </div>
            <% end %>
          </div>
        </div>

        <div :if={@artifact[:body]} class="px-6 py-4">
          <h4 class="font-sans text-2xs text-fg-mute mb-2">preview</h4>
          <div class="text-[13px] text-fg-dim">{@artifact.body}</div>
        </div>
      <% end %>
    </aside>
    """
  end

  @doc """
  The bottom composer input. Decorative by default — callers can pass
  a `placeholder` and optional `phx-submit` wiring later.
  """
  attr :placeholder, :string, default: "say something, or / to call an agent"

  def composer(assigns) do
    ~H"""
    <div class="border-t border-line bg-void px-7 py-3">
      <input
        type="text"
        placeholder={@placeholder}
        class="w-full max-w-[860px] mx-auto block bg-raised border border-line px-4 h-9 text-fg placeholder:text-fg-ghost focus:border-amber focus:outline-0 transition-colors text-[13px]"
      />
    </div>
    """
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Small helpers used by the components
  # ─────────────────────────────────────────────────────────────────────────

  defp shell_glyph(%{kind: :cmd}), do: "$"
  defp shell_glyph(%{kind: :err}), do: "!"
  defp shell_glyph(%{kind: :ok}), do: "✓"
  defp shell_glyph(_), do: " "

  defp shell_glyph_color(%{live?: true}), do: "text-amber animate-blink"
  defp shell_glyph_color(%{kind: :cmd}), do: "text-cyan"
  defp shell_glyph_color(%{kind: :err}), do: "text-red"
  defp shell_glyph_color(%{kind: :ok}), do: "text-green"
  defp shell_glyph_color(_), do: "text-fg-ghost"

  defp shell_text_color(%{live?: true}), do: "text-fg"
  defp shell_text_color(%{kind: :cmd}), do: "text-fg"
  defp shell_text_color(%{kind: :err}), do: "text-red"
  defp shell_text_color(%{kind: :ok}), do: "text-green"
  defp shell_text_color(_), do: "text-fg-dim"

  defp diff_row_bg(:add), do: "bg-green/10"
  defp diff_row_bg(:del), do: "bg-red/10"
  defp diff_row_bg(_), do: ""

  defp diff_marker(:add), do: "+"
  defp diff_marker(:del), do: "−"
  defp diff_marker(_), do: " "

  defp diff_marker_color(:add), do: "text-green"
  defp diff_marker_color(:del), do: "text-red"
  defp diff_marker_color(_), do: "text-fg-ghost"

  defp history_op_color("create"), do: "text-green"
  defp history_op_color("revise"), do: "text-amber"
  defp history_op_color("cite"), do: "text-cyan"
  defp history_op_color(_), do: "text-fg-mute"

  defp mm_ss(pos, total_seconds) do
    cur = floor(pos * total_seconds)
    mm = cur |> div(60) |> to_string() |> String.pad_leading(2, "0")
    ss = cur |> rem(60) |> to_string() |> String.pad_leading(2, "0")
    "#{mm}:#{ss}"
  end

  # ─────────────────────────────────────────────────────────────────────────
  # View model — the whole scenario, as plain data
  # ─────────────────────────────────────────────────────────────────────────

  defp room do
    %{
      slug: "luna-dd",
      me: "mira",
      members_label: "mira, jonas + vale, orr",
      status: "live",
      agents_online: 2,
      age: "3d 4h",
      date_label: %{weekday: "tue", date: "21 april 2026"},
      range: "13:52 — 17:04",
      people: %{
        "mira" => %{name: "mira", color: "text-amber", kind: :human},
        "jonas" => %{name: "jonas", color: "text-pink", kind: :human},
        "vale" => %{name: "vale", color: "text-violet", kind: :agent},
        "orr" => %{name: "orr", color: "text-cyan", kind: :agent}
      },
      sidebar_artifacts: [
        %{
          key: "parsed-invoice",
          glyph: "▣",
          name: "invoice · LV-2026-00412",
          meta: "v2"
        },
        %{
          key: "photo-invoice",
          glyph: "▢",
          name: "invoice photo",
          meta: "heic"
        },
        %{
          key: "payment-shell",
          glyph: "$",
          name: "SEPA signing · 2.2s",
          meta: "4 cmd"
        },
        %{
          key: "code-fix",
          glyph: "▼",
          name: "invoice.tsx · patch",
          meta: "+3/−2"
        },
        %{key: "podcast", glyph: "♪", name: "tuesday dispatch", meta: "6:12"}
      ],
      turns: turns(),
      artifacts: artifacts()
    }
  end

  # Each turn is one visual row in the transcript. `body` is a list of
  # blocks; inline text messages stay short on a single row, artifacts get
  # their own row with `block?: true`.
  defp turns do
    [
      %{
        id: "t0",
        who: "mira",
        time: "13:52",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: ["photo-invoice"],
        body: [
          {:msg,
           [
             "ok small favor — can someone deal with this before I get on the train? soc thing, due today."
           ]}
        ]
      },
      %{
        id: "t0a",
        who: "mira",
        time: "",
        block?: true,
        threaded?: false,
        is_child?: false,
        lineage: ["photo-invoice"],
        body: [
          {:artifact, "photo-invoice",
           caption: "a photograph · 4032×3024 · heic",
           lineage: [],
           kind: :image}
        ]
      },
      %{
        id: "t1",
        who: "vale",
        time: "13:54",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: ["parsed-invoice"],
        body: [
          {:msg,
           [
             "on it. OCR's clean — soc contributions line, plus twelve days interest. authorize below."
           ]}
        ]
      },
      %{
        id: "t1a",
        who: "vale",
        time: "",
        block?: true,
        threaded?: false,
        is_child?: false,
        lineage: ["parsed-invoice"],
        body: [
          {:artifact, "parsed-invoice",
           caption: nil,
           kind: :ledger,
           payer: "State Revenue Service · LV",
           amount: "875.40",
           ref: "ref 2026-00412",
           issued: "2026-04-08",
           due: "2026-04-20 · 12 days past",
           debit: "Swedbank · operating",
           tx_hash: "0x7a1c…4f09",
           settled_at: "14:07",
           lineage: [
             %{label: "from the photograph", link: "photo-invoice"}
           ]}
        ]
      },
      %{
        id: "t2",
        who: "mira",
        time: "14:04",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: ["parsed-invoice"],
        body: [
          {:msg,
           [
             "authorized. ",
             {:mute, "(touch-id, phone)"}
           ]}
        ]
      },
      %{
        id: "t3",
        who: "orr",
        time: "14:05",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: ["payment-shell"],
        body: [
          {:msg,
           [
             "signing from ",
             {:tag, "swedbank · operating"},
             "."
           ]}
        ]
      },
      %{
        id: "t3a",
        who: "orr",
        time: "",
        block?: true,
        threaded?: false,
        is_child?: false,
        lineage: ["payment-shell"],
        body: [
          {:artifact, "payment-shell",
           kind: :shell,
           caption: "SEPA signing · 4 commands · 2.2s",
           lineage: [
             %{label: "binds invoice · LV-2026-00412", link: "parsed-invoice"}
           ],
           lines: [
             %{
               kind: :cmd,
               text:
                 "swed sign --account op --to LV08HABA055100… --amount 87540 --ref 2026-00412"
             },
             %{
               kind: :ok,
               text: "signature captured · mira · 14:05:04",
               ms: "240ms"
             },
             %{kind: :cmd, text: "sepa broadcast --tx 0x7a1c4f09"},
             %{
               kind: :ok,
               text: "accepted by clearer · pending confirmation",
               ms: "612ms"
             },
             %{
               kind: :ok,
               text: "confirmed · block 21,417,308 · fee €0.35",
               ms: "1.3s"
             }
           ]}
        ]
      },
      %{
        id: "t4",
        who: "jonas",
        time: "14:31",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: [],
        body: [
          {:msg,
           [
             {:emoji, "😄"},
             " efficient. also — one small ugly thing."
           ]}
        ]
      },
      %{
        id: "t5",
        who: "jonas",
        time: "14:33",
        block?: true,
        threaded?: false,
        is_child?: false,
        lineage: ["code-fix"],
        body: [
          {:msg,
           [
             "on mobile the amount row walks half a pixel — tabular figures not landing. ",
             {:mention, "@orr"},
             " — this card:"
           ]},
          {:quote,
           source: "parsed-invoice",
           label: "parsed invoice · LV-2026-00412",
           body: ".ledger-row .amt — inconsistent baseline ≤ 440px"}
        ]
      },
      %{
        id: "t6",
        who: "orr",
        time: "14:35",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: ["code-fix"],
        body: [
          {:msg,
           ["read source, three-line patch. tests pass, merged to main."]}
        ]
      },
      %{
        id: "t6a",
        who: "orr",
        time: "",
        block?: true,
        threaded?: false,
        is_child?: false,
        lineage: ["code-fix"],
        body: [
          {:artifact, "code-fix",
           kind: :code,
           caption: "commit be44e1a · main · ci green (18s)",
           lineage: [
             %{label: "prompted by jonas' quote", link: nil},
             %{label: "renders invoice card", link: "parsed-invoice"}
           ],
           path: "src/artifacts/invoice.tsx",
           added: 3,
           deleted: 2,
           lines: [
             %{
               kind: :ctx,
               a: "42",
               b: "42",
               src:
                 ~s|  &lt;div <span class="text-violet">className</span>=<span class="text-peach">"ledger-row"</span>&gt;|
             },
             %{
               kind: :ctx,
               a: "43",
               b: "43",
               src:
                 ~s|    &lt;span <span class="text-violet">className</span>=<span class="text-peach">"when"</span>&gt;{<span class="text-cyan">row</span>.<span class="text-cyan">when</span>}&lt;/span&gt;|
             },
             %{
               kind: :del,
               a: "44",
               b: "",
               src:
                 ~s|    &lt;span <span class="text-violet">className</span>=<span class="text-peach">"amt"</span>&gt;{<span class="text-cyan">row</span>.<span class="text-cyan">amt</span>}&lt;/span&gt;|
             },
             %{
               kind: :add,
               a: "",
               b: "44",
               src:
                 ~s|    &lt;span <span class="text-violet">className</span>=<span class="text-peach">"amt"</span> <span class="text-violet">style</span>={{|
             },
             %{
               kind: :add,
               a: "",
               b: "45",
               src:
                 ~s|      <span class="text-cyan">fontVariantNumeric</span>: <span class="text-peach">"tabular-nums"</span>,|
             },
             %{
               kind: :add,
               a: "",
               b: "46",
               src:
                 ~s|      <span class="text-cyan">fontFeatureSettings</span>: <span class="text-peach">'"tnum"'</span>|
             },
             %{
               kind: :add,
               a: "",
               b: "47",
               src:
                 ~s|    }}&gt;{<span class="text-cyan">row</span>.<span class="text-cyan">amt</span>}&lt;/span&gt;|
             },
             %{kind: :ctx, a: "45", b: "48", src: "  &lt;/div&gt;"}
           ],
           review: %{
             by: "orr",
             html:
               ~s|tests pass <span class="font-mono text-green">42/42</span>, a visual-regression run flagged a 1px baseline shift at <span class="font-mono text-cyan">invoice.tsx:44</span> — patched above.|
           }}
        ]
      },
      %{
        id: "t7",
        who: "vale",
        time: "17:00",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: ["podcast"],
        body: [
          {:msg,
           [
             "tuesday dispatch — six minutes, drawn from the day. transcript lives in the drawer."
           ]}
        ]
      },
      %{
        id: "t7a",
        who: "vale",
        time: "",
        block?: true,
        threaded?: false,
        is_child?: false,
        lineage: ["podcast"],
        body: [
          {:artifact, "podcast",
           kind: :audio,
           caption: nil,
           lineage: [
             %{label: "draws from 34 sources in this room", link: nil},
             %{label: "cites invoice + tax fix", link: "parsed-invoice"}
           ],
           title:
             "tuesday dispatch — tax, tabular figures, the Luna Press ratio",
           duration_label: "06:12",
           duration_seconds: 372,
           waveform: podcast_wave()}
        ]
      },
      %{
        id: "t8",
        who: "mira",
        time: "17:04",
        block?: false,
        threaded?: false,
        is_child?: false,
        lineage: [],
        body: [{:msg, ["good day. shutting the laptop."]}]
      }
    ]
  end

  defp artifacts do
    %{
      "photo-invoice" => %{
        id: "img.20260421.135234",
        kind: :image,
        kind_label: "photograph",
        name: "invoice — Latvian tax authority",
        version: "v1",
        by: "mira",
        created: "2026-04-21 · 13:52",
        ancestors: [],
        descendants: [
          %{kind: "parsed", name: "invoice · LV-2026-00412", by: "vale"},
          %{kind: "cite", name: "tuesday dispatch", by: "vale"}
        ],
        history: [
          %{
            when: "13:52:34",
            op: "create",
            what: "uploaded from phone",
            by: "mira"
          },
          %{
            when: "13:54:12",
            op: "cite",
            what: "referenced by vale/parsed-invoice",
            by: "vale"
          },
          %{
            when: "17:00:42",
            op: "cite",
            what: "cited in podcast (0:14)",
            by: "vale"
          }
        ]
      },
      "parsed-invoice" => %{
        id: "inv.LV-2026-00412",
        kind: :ledger,
        kind_label: "parsed invoice",
        name: "State Revenue Service · LV — €875.40",
        version: "v2",
        by: "vale",
        created: "2026-04-21 · 13:54",
        ancestors: [
          %{
            kind: "photograph",
            name: "invoice — Latvian tax authority",
            by: "mira"
          }
        ],
        descendants: [
          %{kind: "shell", name: "SEPA signing", by: "orr"},
          %{kind: "bug-quote", name: "tabular figures bug", by: "jonas"},
          %{kind: "patch", name: "invoice.tsx · +3/-2", by: "orr"},
          %{kind: "cite", name: "tuesday dispatch", by: "vale"}
        ],
        history: [
          %{
            when: "13:54:12",
            op: "create",
            what: "OCR parsed (9 fields)",
            by: "vale"
          },
          %{
            when: "14:04:58",
            op: "sign",
            what: "authorized by mira (touch-id)",
            by: "mira"
          },
          %{
            when: "14:07:21",
            op: "settle",
            what: "SEPA confirmed · block 21,417,308",
            by: "orr"
          },
          %{
            when: "14:33:02",
            op: "cite",
            what: "quoted as bug reference",
            by: "jonas"
          },
          %{
            when: "14:35:17",
            op: "revise",
            what: "rendered via patched invoice.tsx",
            by: "orr"
          }
        ],
        body:
          "parsed fields: payer, amount, ref, due date, IBAN, issue date, fee code, interest, VAT id."
      },
      "payment-shell" => %{
        id: "run.sepa.tx7a1c4f09",
        kind: :shell,
        kind_label: "shell trace",
        name: "SEPA signing · 4 commands · 2.2s",
        version: "v1",
        by: "orr",
        created: "2026-04-21 · 14:05",
        ancestors: [
          %{kind: "ledger", name: "invoice · LV-2026-00412", by: "vale"}
        ],
        descendants: [
          %{kind: "cite", name: "tuesday dispatch", by: "vale"}
        ],
        history: [
          %{
            when: "14:05:01",
            op: "create",
            what: "signing flow invoked",
            by: "orr"
          },
          %{
            when: "14:05:04",
            op: "sign",
            what: "private key on phone accepted",
            by: "mira"
          },
          %{
            when: "14:05:16",
            op: "emit",
            what: "broadcast to SEPA clearer",
            by: "orr"
          },
          %{
            when: "14:07:21",
            op: "settle",
            what: "confirmed · block 21,417,308",
            by: "orr"
          }
        ]
      },
      "code-fix" => %{
        id: "patch.be44e1a",
        kind: :code,
        kind_label: "code patch",
        name: "invoice.tsx · tabular-nums on .amt",
        version: "v1",
        by: "orr",
        created: "2026-04-21 · 14:35",
        ancestors: [
          %{kind: "quote", name: "jonas flags baseline shift", by: "jonas"},
          %{kind: "ledger", name: "invoice · LV-2026-00412", by: "vale"}
        ],
        descendants: [
          %{kind: "cite", name: "tuesday dispatch", by: "vale"}
        ],
        history: [
          %{
            when: "14:35:02",
            op: "create",
            what: "patch composed from jonas' trace",
            by: "orr"
          },
          %{
            when: "14:35:14",
            op: "test",
            what: "42/42 passing · visual-regression clean",
            by: "orr"
          },
          %{
            when: "14:35:17",
            op: "merge",
            what: "fast-forward to main · commit be44e1a",
            by: "orr"
          }
        ]
      },
      "podcast" => %{
        id: "audio.dispatch.2026-04-21",
        kind: :audio,
        kind_label: "audio · podcast",
        name: "tuesday dispatch — tax, tabular figures, the Luna Press ratio",
        version: "v1",
        by: "vale",
        created: "2026-04-21 · 17:00",
        ancestors: [
          %{kind: "image", name: "invoice photo", by: "mira"},
          %{kind: "ledger", name: "invoice · LV-2026-00412", by: "vale"},
          %{kind: "patch", name: "invoice.tsx · +3/-2", by: "orr"}
        ],
        descendants: [],
        history: [
          %{
            when: "17:00:42",
            op: "create",
            what: "rendered · 6:12 · 34 source citations",
            by: "vale"
          }
        ]
      }
    }
  end

  # Which turns should light up when you hover an artifact (by key).
  defp lineage_for(nil), do: MapSet.new()

  defp lineage_for(key) do
    for turn <- turns(), key in turn.lineage, into: MapSet.new(), do: turn.id
  end

  defp podcast_wave do
    [
      0.3,
      0.5,
      0.7,
      0.4,
      0.8,
      0.6,
      0.9,
      0.5,
      0.3,
      0.7,
      0.8,
      0.5,
      0.4,
      0.6,
      0.9,
      0.7,
      0.8,
      0.5,
      0.6,
      0.4,
      0.3,
      0.7,
      0.9,
      0.8,
      0.5,
      0.6,
      0.4,
      0.7,
      0.3,
      0.5,
      0.8,
      0.6,
      0.9,
      0.7,
      0.4,
      0.5,
      0.3,
      0.8,
      0.6,
      0.7,
      0.4,
      0.9,
      0.5,
      0.6,
      0.3,
      0.8,
      0.7,
      0.5,
      0.4,
      0.6,
      0.9,
      0.7,
      0.3,
      0.5,
      0.8,
      0.6,
      0.4,
      0.7,
      0.9,
      0.5,
      0.3,
      0.6,
      0.8,
      0.4
    ]
  end
end
