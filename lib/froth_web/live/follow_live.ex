defmodule FrothWeb.FollowLive do
  use FrothWeb, :live_view

  alias Froth.Follow.{Entry, Filter, Projector, Source, Timeline}

  @page_size 3000
  @max_entries 5000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :telemetry.attach_many(
        telemetry_handler_id(socket),
        Froth.Telemetry.events(),
        &__MODULE__.handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(:entries, [])
     |> assign(:entry_count, 0)
     |> assign(:expanded_entry_id, nil)
     |> assign(:filter_text, nil)
     |> assign(:follow_filter, Filter.new())
     |> assign(:search_form, search_form(nil))
     |> assign(:view_mode, :smart)
     |> stream_configure(:entries, dom_id: & &1.dom_id)
     |> stream(:entries, [], reset: true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    follow_filter = filter_from_params(params)
    filter_text = normalize_filter_value(params["q"])
    view_mode = parse_view_mode(params["mode"])
    entries = load_recent_entries(follow_filter, filter_text)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:expanded_entry_id, nil)
     |> assign(:filter_text, filter_text)
     |> assign(:follow_filter, follow_filter)
     |> assign(:search_form, search_form(filter_text))
     |> assign(:view_mode, view_mode)
     |> sync_entries()}
  end

  @impl true
  def terminate(_reason, socket) do
    :telemetry.detach(telemetry_handler_id(socket))
    :ok
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, socket) do
    entry = Projector.from_live(event_name, measurements, metadata)

    if matches_entry?(entry, socket.assigns.follow_filter, socket.assigns.filter_text) do
      entries =
        socket.assigns.entries
        |> Kernel.++([entry])
        |> Enum.take(-@max_entries)

      expanded_entry_id =
        if Enum.any?(entries, &(entry_id(&1) == socket.assigns.expanded_entry_id)) do
          socket.assigns.expanded_entry_id
        else
          nil
        end

      {:noreply,
       socket
       |> assign(:entries, entries)
       |> assign(:expanded_entry_id, expanded_entry_id)
       |> sync_entries()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search", %{"filters" => %{"q" => q}}, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, q: q), replace: true)}
  end

  def handle_event("set-mode", %{"mode" => mode}, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, mode: mode))}
  end

  def handle_event("toggle-entry", %{"id" => id}, socket) do
    expanded_entry_id = if socket.assigns.expanded_entry_id == id, do: nil, else: id

    {:noreply,
     socket
     |> assign(:expanded_entry_id, expanded_entry_id)
     |> sync_entries()}
  end

  def handle_event("pin-cycle", %{"cycle" => cycle_id}, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, cycle: cycle_id, span: nil))}
  end

  def handle_event("pin-span", %{"span" => span_id}, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, cycle: nil, span: span_id))}
  end

  def handle_event("clear-scope", _, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, cycle: nil, span: nil))}
  end

  def handle_event("clear-search", _, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, q: nil), replace: true)}
  end

  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(:entries, [])
     |> assign(:expanded_entry_id, nil)
     |> sync_entries()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div
        id="follow-reader"
        phx-hook="ToolScroll"
        data-follow-mode="always"
        class="mini-shell safe-top flex min-h-0 flex-col bg-[radial-gradient(circle_at_top,rgba(28,55,97,0.22),transparent_28%),linear-gradient(180deg,#09090b_0%,#050507_55%,#020203_100%)] font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-zinc-100"
      >
        <header class="sticky top-0 z-30 border-b border-zinc-800/80 bg-zinc-950/90 backdrop-blur-xl">
          <div class="mx-auto flex w-full max-w-6xl flex-col gap-4 px-4 py-4 md:px-6">
            <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div class="space-y-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="inline-flex items-center rounded-full border border-sky-400/25 bg-sky-400/10 px-2.5 py-1 text-[10px] uppercase tracking-[0.18em] text-sky-100">
                    Execution Reader
                  </span>
                  <span class="inline-flex items-center gap-1 rounded-full border border-emerald-400/20 bg-emerald-400/10 px-2.5 py-1 text-[10px] uppercase tracking-[0.18em] text-emerald-100">
                    <span class="inline-block size-1.5 rounded-full bg-emerald-300"></span> Live tail
                  </span>
                </div>
                <div>
                  <h1 class="text-xl font-semibold tracking-tight text-zinc-50">Follow</h1>
                  <p class="max-w-2xl text-[12px] leading-5 text-zinc-400">
                    Recent execution history from `events`, projected into a readable run log and kept
                    live with telemetry.
                  </p>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-2 self-start">
                <button
                  id="follow-mode-smart"
                  type="button"
                  phx-click="set-mode"
                  phx-value-mode="smart"
                  class={[
                    "inline-flex min-h-9 items-center rounded-xl border px-3 text-[11px] uppercase tracking-[0.16em] transition",
                    if(@view_mode == :smart,
                      do:
                        "border-zinc-100 bg-zinc-100 text-zinc-950 shadow-[0_10px_30px_rgba(255,255,255,0.08)]",
                      else:
                        "border-zinc-700 bg-zinc-900/70 text-zinc-300 hover:border-zinc-500 hover:text-zinc-100"
                    )
                  ]}
                >
                  Smart
                </button>
                <button
                  id="follow-mode-raw"
                  type="button"
                  phx-click="set-mode"
                  phx-value-mode="raw"
                  class={[
                    "inline-flex min-h-9 items-center rounded-xl border px-3 text-[11px] uppercase tracking-[0.16em] transition",
                    if(@view_mode == :raw,
                      do:
                        "border-zinc-100 bg-zinc-100 text-zinc-950 shadow-[0_10px_30px_rgba(255,255,255,0.08)]",
                      else:
                        "border-zinc-700 bg-zinc-900/70 text-zinc-300 hover:border-zinc-500 hover:text-zinc-100"
                    )
                  ]}
                >
                  Raw
                </button>
                <button
                  id="follow-mode-errors"
                  type="button"
                  phx-click="set-mode"
                  phx-value-mode="errors"
                  class={[
                    "inline-flex min-h-9 items-center rounded-xl border px-3 text-[11px] uppercase tracking-[0.16em] transition",
                    if(@view_mode == :errors,
                      do:
                        "border-amber-200 bg-amber-100 text-amber-950 shadow-[0_10px_30px_rgba(251,191,36,0.12)]",
                      else:
                        "border-zinc-700 bg-zinc-900/70 text-zinc-300 hover:border-zinc-500 hover:text-zinc-100"
                    )
                  ]}
                >
                  Errors
                </button>
                <button
                  id="follow-clear"
                  type="button"
                  phx-click="clear"
                  class="inline-flex min-h-9 items-center rounded-xl border border-zinc-700 bg-zinc-900/70 px-3 text-[11px] uppercase tracking-[0.16em] text-zinc-300 transition hover:border-zinc-500 hover:text-zinc-100"
                >
                  Clear
                </button>
                <span class="text-[11px] uppercase tracking-[0.18em] text-zinc-500">
                  {@entry_count} shown
                </span>
              </div>
            </div>

            <div class="flex flex-col gap-3 xl:flex-row xl:items-end xl:justify-between">
              <.form
                for={@search_form}
                id="follow-search"
                phx-change="search"
                class="w-full xl:max-w-md"
              >
                <.input
                  field={@search_form[:q]}
                  type="text"
                  id="follow-search-input"
                  placeholder="Search event, detail, metadata"
                  phx-debounce="300"
                  class="h-11 w-full rounded-2xl border border-zinc-800 bg-zinc-900/80 px-4 text-[13px] text-zinc-100 placeholder:text-zinc-500 focus:border-sky-400/60 focus:outline-none focus:ring-0"
                />
              </.form>

              <div class="flex flex-wrap items-center gap-2">
                <span
                  :if={@follow_filter.cycle_id}
                  class="inline-flex items-center gap-2 rounded-full border border-sky-400/30 bg-sky-400/10 px-3 py-1.5 text-[11px] text-sky-100"
                >
                  <.icon name="hero-arrow-path-rounded-square" class="size-3.5 text-sky-300" />
                  cycle {truncate_id(@follow_filter.cycle_id, 12)}
                </span>
                <span
                  :if={@follow_filter.span_id}
                  class="inline-flex items-center gap-2 rounded-full border border-violet-400/30 bg-violet-400/10 px-3 py-1.5 text-[11px] text-violet-100"
                >
                  <.icon name="hero-arrows-right-left" class="size-3.5 text-violet-300" />
                  span {truncate_id(@follow_filter.span_id, 12)}
                </span>
                <button
                  :if={@filter_text}
                  id="follow-clear-search"
                  type="button"
                  phx-click="clear-search"
                  class="inline-flex min-h-9 items-center rounded-full border border-zinc-700 bg-zinc-900/70 px-3 text-[11px] uppercase tracking-[0.16em] text-zinc-300 transition hover:border-zinc-500 hover:text-zinc-100"
                >
                  Clear search
                </button>
                <button
                  :if={@follow_filter.cycle_id || @follow_filter.span_id}
                  id="follow-clear-scope"
                  type="button"
                  phx-click="clear-scope"
                  class="inline-flex min-h-9 items-center rounded-full border border-zinc-700 bg-zinc-900/70 px-3 text-[11px] uppercase tracking-[0.16em] text-zinc-300 transition hover:border-zinc-500 hover:text-zinc-100"
                >
                  Clear scope
                </button>
              </div>
            </div>
          </div>
        </header>

        <main
          id="follow-feed"
          data-scroll-body
          class="min-h-0 flex-1 overflow-y-auto overscroll-contain"
        >
          <div class="mx-auto w-full max-w-6xl px-4 py-5 md:px-6 md:py-6">
            <div id="follow-entries" phx-update="stream" class="space-y-4">
              <div
                id="follow-empty-state"
                class="hidden rounded-3xl border border-dashed border-zinc-800 bg-zinc-950/80 px-6 py-10 text-center only:block"
              >
                <p class="text-[12px] uppercase tracking-[0.2em] text-zinc-500">
                  No matching entries
                </p>
                <p class="mt-2 text-[13px] leading-6 text-zinc-400">
                  Adjust the search, clear scope pinning, or wait for new telemetry.
                </p>
              </div>

              <%= for {dom_id, item} <- @streams.entries do %>
                <div id={dom_id}>
                  <%= if item.group_break? do %>
                    <%= if item.group_kind == :cycle and item.cycle_summary do %>
                      <section
                        id={"follow-cycle-summary-#{item.cycle_summary.cycle_id}"}
                        class={cycle_summary_container_class(item)}
                      >
                        <div class={cycle_summary_bar_class(item.cycle_accent)}></div>
                        <div class="space-y-3 px-3 py-3">
                          <div class="flex flex-wrap items-center gap-2 text-[10px] uppercase tracking-[0.18em] text-zinc-500">
                            <span class={cycle_summary_label_class(item.cycle_accent)}>
                              cycle {item.cycle_summary.label}
                            </span>
                            <span class={status_badge_class(item.cycle_summary.status_level)}>
                              {item.cycle_summary.status}
                            </span>
                            <span
                              :if={item.cycle_summary.active?}
                              class="inline-flex items-center gap-1 rounded-full border border-emerald-400/20 bg-emerald-400/10 px-2 py-0.5 text-emerald-100"
                            >
                              <span class="inline-block size-1.5 rounded-full bg-emerald-300"></span>
                              live
                            </span>
                          </div>

                          <div class="grid gap-2 sm:grid-cols-2">
                            <div class="min-w-0 text-[11px] leading-5 text-zinc-200">
                              <span :if={item.cycle_summary.provider || item.cycle_summary.model}>
                                {cycle_identity_text(item.cycle_summary)}
                              </span>
                              <span :if={item.cycle_summary.provider || item.cycle_summary.model}>
                                {" "}
                              </span>
                              <span class="text-zinc-400">
                                tools {item.cycle_summary.tool_count}
                              </span>
                              <span :if={item.cycle_summary.llm_count > 0} class="text-zinc-400">
                                {" "}llm {item.cycle_summary.llm_count}
                              </span>
                            </div>

                            <div class="flex flex-wrap items-center gap-2 text-[10px] uppercase tracking-[0.16em] text-zinc-500 sm:justify-end">
                              <span
                                :if={item.cycle_summary.elapsed_ms}
                                class="rounded-full border border-zinc-700 bg-zinc-900/80 px-2 py-0.5 text-zinc-300"
                              >
                                elapsed {format_elapsed(item.cycle_summary.elapsed_ms)}
                              </span>
                              <span class="rounded-full border border-zinc-800 bg-black/30 px-2 py-0.5 text-zinc-500">
                                cycle summary
                              </span>
                            </div>
                          </div>
                        </div>
                      </section>
                    <% else %>
                      <div class="mb-2 flex items-center gap-3 px-1 text-[10px] uppercase tracking-[0.24em] text-zinc-500">
                        <span class={group_label_class(item.group_kind)}>{item.group_label}</span>
                        <div class="h-px flex-1 bg-zinc-800"></div>
                      </div>
                    <% end %>
                  <% end %>

                  <article class={entry_container_class(item)}>
                    <button
                      id={"follow-entry-toggle-#{item.entry.id}"}
                      type="button"
                      phx-click="toggle-entry"
                      phx-value-id={entry_id(item.entry)}
                      class="block w-full text-left"
                    >
                      <div class="grid grid-cols-[5.05rem_3.9rem_5.6rem_minmax(0,1fr)] gap-x-2 gap-y-2 sm:grid-cols-[5.4rem_4.5rem_7.5rem_minmax(0,1fr)]">
                        <span class="truncate text-[11px] tabular-nums text-zinc-500">
                          {format_time(item.entry.at)}
                        </span>

                        <span class={family_column_class(item.entry)}>
                          {family_short_label(item.entry.family)}
                        </span>

                        <span class={scope_column_class(item.entry)}>
                          {item.entry.scope || "-"}
                        </span>

                        <div class="min-w-0">
                          <div class="flex min-w-0 items-start gap-2">
                            <span class={tree_prefix_class(item)}>
                              {item.tree_prefix}
                            </span>

                            <div class="min-w-0 flex-1">
                              <div class="flex items-start justify-between gap-3">
                                <div class="min-w-0 flex-1">
                                  <p class={summary_class(item.entry)}>
                                    {entry_primary_text(item.entry, @view_mode)}
                                  </p>
                                  <p
                                    :if={entry_secondary_text(item.entry, @view_mode)}
                                    class={secondary_text_class(item.entry)}
                                  >
                                    {entry_secondary_text(item.entry, @view_mode)}
                                  </p>
                                </div>

                                <span class="shrink-0 rounded-full border border-zinc-700 bg-zinc-900/70 px-2.5 py-1 text-[10px] uppercase tracking-[0.16em] text-zinc-400 transition group-hover:text-zinc-100">
                                  {if(item.expanded?, do: "Hide", else: "Payload")}
                                </span>
                              </div>
                            </div>
                          </div>
                        </div>
                      </div>
                    </button>

                    <div class="mt-2 flex flex-wrap items-center gap-2">
                      <span
                        :if={item.entry.duration_ms}
                        class="rounded-full border border-zinc-700 bg-zinc-900/80 px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-zinc-300"
                      >
                        {item.entry.duration_ms} ms
                      </span>
                      <span
                        :if={exit_code(item.entry)}
                        class={exit_badge_class(exit_code(item.entry))}
                      >
                        exit {exit_code(item.entry)}
                      </span>
                      <button
                        :if={item.entry.cycle_id}
                        id={"follow-pin-cycle-#{item.entry.id}"}
                        type="button"
                        phx-click="pin-cycle"
                        phx-value-cycle={item.entry.cycle_id}
                        class={pin_button_class(:cycle)}
                      >
                        <.icon name="hero-arrow-path-rounded-square" class="size-3.5" />
                        cycle {truncate_id(item.entry.cycle_id, 10)}
                      </button>
                      <button
                        :if={item.entry.span_id}
                        id={"follow-pin-span-#{item.entry.id}"}
                        type="button"
                        phx-click="pin-span"
                        phx-value-span={item.entry.span_id}
                        class={pin_button_class(:span)}
                      >
                        <.icon name="hero-arrows-right-left" class="size-3.5" />
                        span {truncate_id(item.entry.span_id, 10)}
                      </button>
                      <span
                        :if={item.entry.parent_id}
                        class="inline-flex items-center gap-1 rounded-full border border-zinc-700 bg-zinc-900/60 px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-zinc-500"
                      >
                        <.icon name="hero-arrow-turn-down-right" class="size-3.5" />
                        parent {truncate_id(item.entry.parent_id, 10)}
                      </span>
                    </div>

                    <div
                      :if={item.expanded?}
                      id={"follow-entry-detail-#{item.entry.id}"}
                      class="mt-4 border-t border-zinc-800/80 pt-4"
                    >
                      <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
                        <p class="text-[10px] uppercase tracking-[0.2em] text-zinc-500">
                          Full payload
                        </p>
                        <p class="break-all text-[11px] text-zinc-600">{item.entry.event}</p>
                      </div>
                      <pre
                        id={"follow-entry-json-#{item.entry.id}"}
                        phx-no-curly-interpolation
                        class="overflow-x-auto rounded-2xl border border-zinc-800 bg-black/60 p-4 text-[11px] leading-5 text-zinc-300"
                      ><%= entry_payload_json(item.entry, @view_mode) %></pre>
                    </div>
                  </article>
                </div>
              <% end %>
            </div>

            <div id="tool-feed-end" data-scroll-end></div>
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp load_recent_entries(%Filter{} = follow_filter, text_filter) do
    Source.recent_entries(filter: follow_filter, text: text_filter, limit: @page_size)
    |> Enum.reverse()
  end

  defp sync_entries(socket) do
    matching_entries =
      socket.assigns.entries
      |> matching_entries(socket.assigns.follow_filter, socket.assigns.filter_text)

    visible_entries = Enum.filter(matching_entries, &Entry.visible?(&1, socket.assigns.view_mode))
    tree_map = Timeline.tree_map(visible_entries)
    cycle_summaries = Timeline.cycle_summaries(matching_entries)

    stream_items =
      build_stream_items(
        visible_entries,
        socket.assigns.expanded_entry_id,
        tree_map,
        cycle_summaries
      )

    socket
    |> assign(:entry_count, length(stream_items))
    |> stream(:entries, stream_items, reset: true)
  end

  defp matching_entries(entries, %Filter{} = follow_filter, text_filter) do
    Enum.filter(entries, fn entry ->
      Filter.matches?(entry, follow_filter) and matches_text?(entry, text_filter)
    end)
  end

  defp build_stream_items(entries, expanded_entry_id, tree_map, cycle_summaries) do
    {items, _previous} =
      Enum.map_reduce(entries, nil, fn entry, previous_entry ->
        tree_info = Map.get(tree_map, entry_id(entry), %{depth: 0, prefix: ""})

        item = %{
          dom_id: "follow-entry-#{entry_id(entry)}",
          entry: entry,
          expanded?: entry_id(entry) == expanded_entry_id,
          group_break?: group_key(entry) != group_key(previous_entry),
          group_kind: group_kind(entry),
          group_label: group_label(entry),
          tree_prefix: tree_info.prefix,
          depth: tree_info.depth,
          cycle_summary: cycle_summaries[entry.cycle_id],
          cycle_accent: cycle_accent(entry.cycle_id)
        }

        {item, entry}
      end)

    items
  end

  defp matches_entry?(%Entry{} = entry, %Filter{} = follow_filter, text_filter) do
    Filter.matches?(entry, follow_filter) and matches_text?(entry, text_filter)
  end

  defp matches_text?(_entry, nil), do: true

  defp matches_text?(entry, text) do
    needle = String.downcase(text)

    haystack =
      [
        entry.event,
        entry.family,
        entry.kind,
        entry.scope,
        entry.summary,
        entry.detail,
        inspect(entry.measurements, pretty: false, printable_limit: 400, limit: 20),
        inspect(entry.metadata, pretty: false, printable_limit: 400, limit: 20)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join("\n")

    String.contains?(haystack, needle)
  end

  defp filter_from_params(params) do
    Filter.new(
      cycle_id: params["cycle"],
      span_id: params["span"]
    )
  end

  defp parse_view_mode("raw"), do: :raw
  defp parse_view_mode("errors"), do: :errors
  defp parse_view_mode(_), do: :smart

  defp follow_path(socket, overrides) do
    params =
      %{
        "cycle" => socket.assigns.follow_filter.cycle_id,
        "span" => socket.assigns.follow_filter.span_id,
        "q" => normalize_filter_value(socket.assigns.filter_text),
        "mode" => mode_param(socket.assigns.view_mode)
      }
      |> merge_query_overrides(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    ~p"/froth/follow?#{params}"
  end

  defp merge_query_overrides(params, overrides) do
    Enum.reduce(overrides, params, fn {key, value}, acc ->
      Map.put(acc, to_string(key), normalize_query_value(key, value))
    end)
  end

  defp normalize_query_value(:mode, value), do: mode_param(parse_view_mode(value))
  defp normalize_query_value("mode", value), do: mode_param(parse_view_mode(value))
  defp normalize_query_value(_key, value), do: normalize_filter_value(value)

  defp mode_param(:raw), do: "raw"
  defp mode_param(:errors), do: "errors"
  defp mode_param(:smart), do: nil

  defp normalize_filter_value(nil), do: nil

  defp normalize_filter_value(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp search_form(filter_text), do: to_form(%{"q" => filter_text || ""}, as: :filters)

  defp telemetry_handler_id(socket), do: "follow-live-#{inspect(socket.root_pid || self())}"

  defp entry_id(%Entry{id: id}), do: to_string(id)

  defp format_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(%NaiveDateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(_), do: "--:--:--.---"

  defp entry_primary_text(entry, :raw), do: entry.event
  defp entry_primary_text(%Entry{summary: summary}, _mode), do: summary

  defp entry_secondary_text(entry, :raw) do
    join_sentence([
      raw_measurements(entry.measurements),
      raw_metadata(entry.metadata)
    ])
  end

  defp entry_secondary_text(%Entry{} = entry, mode) when mode in [:smart, :errors] do
    join_sentence([
      entry.detail,
      smart_context(entry)
    ])
  end

  defp smart_context(%Entry{family: family} = entry) do
    context =
      case family do
        "tool" ->
          join_sentence([
            entry.tool_use_id && "call=#{truncate_id(entry.tool_use_id, 10)}"
          ])

        "llm" ->
          join_sentence([
            entry.kind != "edit" && "kind=#{entry.kind}"
          ])

        "telegram" ->
          join_sentence([
            entry.message_id && "message=#{truncate_id(entry.message_id, 10)}"
          ])

        "control" ->
          join_sentence([
            entry.tool_use_id && "call=#{truncate_id(entry.tool_use_id, 10)}"
          ])

        _ ->
          nil
      end

    context
  end

  defp raw_measurements(measurements) when map_size(measurements) == 0, do: nil

  defp raw_measurements(measurements) do
    measurements
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
    |> Enum.join(" ")
  end

  defp raw_metadata(metadata) when map_size(metadata) == 0, do: nil

  defp raw_metadata(metadata) do
    metadata
    |> Map.drop(["system_time"])
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
    |> Enum.join(" ")
    |> truncate_text(220)
  end

  defp format_value(value) when is_binary(value), do: truncate_text(value, 80)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(value), do: inspect(value, limit: 10, printable_limit: 80)

  defp entry_payload_json(entry, mode) do
    payload =
      case mode do
        :raw ->
          %{
            id: entry.id,
            at: iso8601(entry.at),
            event: entry.event,
            span_id: entry.span_id,
            parent_id: entry.parent_id,
            measurements: entry.measurements,
            metadata: entry.metadata
          }

        mode when mode in [:smart, :errors] ->
          %{
            id: entry.id,
            at: iso8601(entry.at),
            family: entry.family,
            kind: entry.kind,
            level: entry.level,
            scope: entry.scope,
            summary: entry.summary,
            detail: entry.detail,
            duration_ms: entry.duration_ms,
            cycle_id: entry.cycle_id,
            span_id: entry.span_id,
            parent_id: entry.parent_id,
            tool_use_id: entry.tool_use_id,
            message_id: entry.message_id,
            measurements: entry.measurements,
            metadata: entry.metadata,
            event: entry.event
          }
      end

    payload
    |> Jason.encode_to_iodata!()
    |> Jason.Formatter.pretty_print()
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso8601(_), do: nil

  defp truncate_text(value, max) when is_binary(value) and byte_size(value) > max,
    do: String.slice(value, 0, max) <> "..."

  defp truncate_text(value, _max), do: value

  defp truncate_id(nil, _max), do: nil

  defp truncate_id(value, max) do
    value
    |> to_string()
    |> String.slice(0, max)
  end

  defp join_sentence(parts) do
    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp group_key(nil), do: nil
  defp group_key(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id), do: {:cycle, cycle_id}
  defp group_key(%Entry{span_id: span_id}) when is_binary(span_id), do: {:span, span_id}
  defp group_key(%Entry{family: family}), do: {:family, family_group_key(family)}

  defp group_kind(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id), do: :cycle
  defp group_kind(%Entry{span_id: span_id}) when is_binary(span_id), do: :span
  defp group_kind(%Entry{family: family}), do: family_group_key(family)

  defp group_label(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id),
    do: "cycle #{truncate_id(cycle_id, 12)}"

  defp group_label(%Entry{span_id: span_id}) when is_binary(span_id),
    do: "span #{truncate_id(span_id, 12)}"

  defp group_label(%Entry{family: family}), do: "#{family_label(family)} stream"

  defp group_label_class(:cycle),
    do: "rounded-full border border-sky-400/25 bg-sky-400/10 px-3 py-1 text-sky-100"

  defp group_label_class(:span),
    do: "rounded-full border border-violet-400/25 bg-violet-400/10 px-3 py-1 text-violet-100"

  defp group_label_class(:agent),
    do: "rounded-full border border-sky-400/20 bg-sky-400/10 px-3 py-1 text-sky-100"

  defp group_label_class(:tool),
    do: "rounded-full border border-emerald-400/20 bg-emerald-400/10 px-3 py-1 text-emerald-100"

  defp group_label_class(:llm),
    do: "rounded-full border border-fuchsia-400/20 bg-fuchsia-400/10 px-3 py-1 text-fuchsia-100"

  defp group_label_class(:telegram),
    do: "rounded-full border border-sky-400/20 bg-sky-400/10 px-3 py-1 text-sky-100"

  defp group_label_class(_),
    do: "rounded-full border border-zinc-700 bg-zinc-900/70 px-3 py-1 text-zinc-300"

  defp entry_container_class(item) do
    [
      "overflow-hidden rounded-2xl border border-l-4 px-3 py-3 shadow-[0_18px_45px_rgba(0,0,0,0.28)] transition duration-150 hover:border-zinc-600/80 hover:bg-zinc-950/95 sm:px-4",
      cycle_border_class(item.cycle_accent),
      family_surface_class(item.entry),
      item.expanded? && "ring-1 ring-inset ring-zinc-200/8"
    ]
  end

  defp family_column_class(entry),
    do: ["truncate text-[11px] uppercase tracking-[0.18em]", family_column_palette(entry)]

  defp scope_column_class(%Entry{family: "think"}),
    do: "truncate text-[11px] text-cyan-200/70"

  defp scope_column_class(%Entry{}), do: "truncate text-[11px] text-zinc-400"

  defp tree_prefix_class(item) do
    [
      "shrink-0 whitespace-pre text-[11px] leading-5",
      item.depth > 0 && cycle_tree_palette(item.cycle_accent),
      item.depth == 0 && "text-zinc-700"
    ]
  end

  defp summary_class(%Entry{level: :error}),
    do: "text-[13px] font-semibold leading-5 text-rose-200"

  defp summary_class(%Entry{level: :warn}),
    do: "text-[13px] font-semibold leading-5 text-amber-100"

  defp summary_class(%Entry{family: "cycle"}),
    do: "text-[13px] font-semibold leading-5 text-sky-100"

  defp summary_class(%Entry{family: "think"}),
    do: "text-[13px] font-medium leading-5 text-cyan-100/75"

  defp summary_class(%Entry{family: "tool"}),
    do: "text-[13px] font-semibold leading-5 text-emerald-100"

  defp summary_class(%Entry{family: family}) when family in ["llm", "codex"],
    do: "text-[13px] font-semibold leading-5 text-fuchsia-100"

  defp summary_class(%Entry{family: "telegram"}),
    do: "text-[13px] font-semibold leading-5 text-sky-100"

  defp summary_class(%Entry{family: "task"}),
    do: "text-[13px] font-semibold leading-5 text-teal-100"

  defp summary_class(%Entry{}), do: "text-[13px] font-semibold leading-5 text-zinc-50"

  defp secondary_text_class(%Entry{family: "think"}),
    do: "mt-1 whitespace-pre-wrap break-words text-[11px] leading-5 text-cyan-100/55"

  defp secondary_text_class(%Entry{level: :error}),
    do: "mt-1 whitespace-pre-wrap break-words text-[11px] leading-5 text-rose-200/80"

  defp secondary_text_class(%Entry{}),
    do: "mt-1 whitespace-pre-wrap break-words text-[11px] leading-5 text-zinc-400"

  defp family_short_label("control"), do: "ctrl"
  defp family_short_label("message"), do: "msg"
  defp family_short_label("telegram"), do: "tg"
  defp family_short_label(family), do: family

  defp family_label(family) do
    case family do
      "control" ->
        "control"

      "message" ->
        "message"

      _ ->
        case family_group_key(family) do
          :agent -> "agent"
          :tool -> "tool"
          :llm -> "llm"
          :telegram -> "telegram"
          :system -> "system"
        end
    end
  end

  defp family_surface_class(%Entry{level: :error}),
    do: "border-rose-500/30 bg-rose-950/25"

  defp family_surface_class(%Entry{level: :warn}),
    do: "border-amber-500/25 bg-amber-950/18"

  defp family_surface_class(%Entry{family: "cycle"}),
    do: "border-sky-500/20 bg-sky-950/18"

  defp family_surface_class(%Entry{family: "think"}),
    do: "border-cyan-500/20 bg-cyan-950/10 opacity-80"

  defp family_surface_class(%Entry{family: "tool"}),
    do: "border-emerald-500/20 bg-emerald-950/16"

  defp family_surface_class(%Entry{family: family}) when family in ["llm", "codex"],
    do: "border-fuchsia-500/20 bg-fuchsia-950/16"

  defp family_surface_class(%Entry{family: "telegram"}),
    do: "border-sky-500/20 bg-sky-950/16"

  defp family_surface_class(%Entry{family: "task"}),
    do: "border-teal-500/20 bg-teal-950/14"

  defp family_surface_class(%Entry{}), do: "border-zinc-800 bg-zinc-950/85"

  defp family_column_palette(%Entry{level: :error}), do: "text-rose-200"
  defp family_column_palette(%Entry{level: :warn}), do: "text-amber-100"
  defp family_column_palette(%Entry{family: "cycle"}), do: "text-sky-100"
  defp family_column_palette(%Entry{family: "think"}), do: "text-cyan-100/75"
  defp family_column_palette(%Entry{family: "tool"}), do: "text-emerald-100"

  defp family_column_palette(%Entry{family: family}) when family in ["llm", "codex"],
    do: "text-fuchsia-100"

  defp family_column_palette(%Entry{family: "telegram"}), do: "text-sky-100"
  defp family_column_palette(%Entry{family: "task"}), do: "text-teal-100"
  defp family_column_palette(%Entry{}), do: "text-zinc-300"

  defp pin_button_class(:cycle),
    do:
      "inline-flex items-center gap-1 rounded-full border border-sky-400/30 bg-sky-400/10 px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-sky-100 transition hover:bg-sky-400/20"

  defp pin_button_class(:span),
    do:
      "inline-flex items-center gap-1 rounded-full border border-violet-400/30 bg-violet-400/10 px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-violet-100 transition hover:bg-violet-400/20"

  defp cycle_summary_container_class(item) do
    [
      "overflow-hidden rounded-2xl border border-zinc-800/80 bg-zinc-950/90 shadow-[0_20px_50px_rgba(0,0,0,0.24)]",
      cycle_summary_ring_class(item.cycle_accent)
    ]
  end

  defp cycle_summary_bar_class(accent), do: ["h-1 w-full", accent.bg]

  defp cycle_summary_label_class(accent) do
    [
      "inline-flex items-center rounded-full border px-2 py-0.5",
      accent.badge
    ]
  end

  defp status_badge_class(:error),
    do:
      "inline-flex items-center rounded-full border border-rose-400/30 bg-rose-400/10 px-2 py-0.5 text-rose-100"

  defp status_badge_class(:warn),
    do:
      "inline-flex items-center rounded-full border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-amber-100"

  defp status_badge_class(_level),
    do:
      "inline-flex items-center rounded-full border border-zinc-700 bg-zinc-900/80 px-2 py-0.5 text-zinc-200"

  defp cycle_identity_text(summary) do
    case {summary.provider, summary.model} do
      {provider, model} when is_binary(provider) and is_binary(model) -> "#{provider}:#{model}"
      {provider, nil} when is_binary(provider) -> provider
      {nil, model} when is_binary(model) -> model
      _ -> nil
    end
  end

  defp format_elapsed(value) when is_integer(value) and value >= 1_000,
    do: :io_lib.format("~.1fs", [value / 1_000]) |> IO.iodata_to_binary()

  defp format_elapsed(value) when is_integer(value), do: "#{value}ms"
  defp format_elapsed(_value), do: nil

  defp exit_code(%Entry{metadata: metadata}) do
    case metadata["exit_code"] do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp exit_badge_class(code) when is_integer(code) and code != 0,
    do:
      "rounded-full border border-rose-400/30 bg-rose-400/10 px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-rose-100"

  defp exit_badge_class(_code),
    do:
      "rounded-full border border-zinc-700 bg-zinc-900/80 px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-zinc-300"

  defp cycle_accent(nil) do
    %{
      bg: "bg-zinc-700",
      badge: "border-zinc-700 bg-zinc-900/80 text-zinc-300",
      ring: "ring-zinc-700/40",
      border: "border-l-zinc-700",
      tree: "text-zinc-600"
    }
  end

  defp cycle_accent(cycle_id) do
    palettes = [
      %{
        bg: "bg-sky-400/80",
        badge: "border-sky-400/30 bg-sky-400/10 text-sky-100",
        ring: "ring-sky-400/20",
        border: "border-l-sky-400",
        tree: "text-sky-200/80"
      },
      %{
        bg: "bg-cyan-400/80",
        badge: "border-cyan-400/30 bg-cyan-400/10 text-cyan-100",
        ring: "ring-cyan-400/20",
        border: "border-l-cyan-400",
        tree: "text-cyan-200/80"
      },
      %{
        bg: "bg-emerald-400/80",
        badge: "border-emerald-400/30 bg-emerald-400/10 text-emerald-100",
        ring: "ring-emerald-400/20",
        border: "border-l-emerald-400",
        tree: "text-emerald-200/80"
      },
      %{
        bg: "bg-fuchsia-400/80",
        badge: "border-fuchsia-400/30 bg-fuchsia-400/10 text-fuchsia-100",
        ring: "ring-fuchsia-400/20",
        border: "border-l-fuchsia-400",
        tree: "text-fuchsia-200/80"
      },
      %{
        bg: "bg-amber-400/80",
        badge: "border-amber-400/30 bg-amber-400/10 text-amber-100",
        ring: "ring-amber-400/20",
        border: "border-l-amber-400",
        tree: "text-amber-200/80"
      },
      %{
        bg: "bg-rose-400/80",
        badge: "border-rose-400/30 bg-rose-400/10 text-rose-100",
        ring: "ring-rose-400/20",
        border: "border-l-rose-400",
        tree: "text-rose-200/80"
      }
    ]

    Enum.at(palettes, :erlang.phash2(cycle_id, length(palettes)))
  end

  defp cycle_summary_ring_class(accent), do: ["ring-1 ring-inset", accent.ring]
  defp cycle_border_class(accent), do: accent.border
  defp cycle_tree_palette(accent), do: accent.tree

  defp family_group_key(family) when family in ["cycle", "think", "control", "message"],
    do: :agent

  defp family_group_key("tool"), do: :tool
  defp family_group_key("llm"), do: :llm
  defp family_group_key("codex"), do: :llm
  defp family_group_key("telegram"), do: :telegram
  defp family_group_key(_), do: :system
end
