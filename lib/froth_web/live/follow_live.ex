defmodule FrothWeb.FollowLive do
  use FrothWeb, :live_view

  alias Froth.Follow.{Entry, Filter, Projector, Source}

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
        class="min-h-screen bg-[radial-gradient(circle_at_top,rgba(28,55,97,0.22),transparent_28%),linear-gradient(180deg,#09090b_0%,#050507_55%,#020203_100%)] font-mono text-zinc-100"
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

        <main id="follow-feed" class="mx-auto w-full max-w-6xl px-4 py-5 md:px-6 md:py-6">
          <div id="follow-entries" phx-update="stream" class="space-y-4">
            <div
              id="follow-empty-state"
              class="hidden rounded-3xl border border-dashed border-zinc-800 bg-zinc-950/80 px-6 py-10 text-center only:block"
            >
              <p class="text-[12px] uppercase tracking-[0.2em] text-zinc-500">No matching entries</p>
              <p class="mt-2 text-[13px] leading-6 text-zinc-400">
                Adjust the search, clear scope pinning, or wait for new telemetry.
              </p>
            </div>

            <%= for {dom_id, item} <- @streams.entries do %>
              <div id={dom_id}>
                <div
                  :if={item.group_break?}
                  class="mb-2 flex items-center gap-3 px-1 text-[10px] uppercase tracking-[0.24em] text-zinc-500"
                >
                  <span class={group_label_class(item.group_kind)}>{item.group_label}</span>
                  <div class="h-px flex-1 bg-zinc-800"></div>
                </div>

                <article class={entry_container_class(item.entry.family, item.expanded?)}>
                  <button
                    id={"follow-entry-toggle-#{item.entry.id}"}
                    type="button"
                    phx-click="toggle-entry"
                    phx-value-id={entry_id(item.entry)}
                    class="block w-full text-left"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-2 text-[11px] text-zinc-500">
                          <span>{format_time(item.entry.at)}</span>
                          <span class={family_badge_class(item.entry.family)}>
                            {family_label(item.entry.family)}
                          </span>
                          <span
                            :if={item.entry.duration_ms}
                            class="rounded-full border border-zinc-700 bg-zinc-900/60 px-2 py-0.5 text-[10px] text-zinc-400"
                          >
                            {item.entry.duration_ms} ms
                          </span>
                        </div>

                        <div class="mt-3 flex items-start gap-3">
                          <div class={icon_wrap_class(item.entry.family)}>
                            <.icon name={entry_icon(item.entry.family)} class="size-4" />
                          </div>

                          <div class="min-w-0 flex-1">
                            <p class={summary_class(item.entry.level)}>
                              {entry_title(item.entry, @view_mode)}
                            </p>
                            <p
                              :if={entry_subtitle(item.entry, @view_mode)}
                              class="mt-1 whitespace-pre-wrap break-words text-[12px] leading-5 text-zinc-400"
                            >
                              {entry_subtitle(item.entry, @view_mode)}
                            </p>
                          </div>
                        </div>
                      </div>

                      <span class="shrink-0 rounded-full border border-zinc-700 bg-zinc-900/70 px-2.5 py-1 text-[10px] uppercase tracking-[0.16em] text-zinc-400 transition group-hover:text-zinc-100">
                        {if(item.expanded?, do: "Hide", else: "Payload")}
                      </span>
                    </div>
                  </button>

                  <div class="mt-3 flex flex-wrap items-center gap-2">
                    <button
                      :if={item.entry.cycle_id}
                      id={"follow-pin-cycle-#{item.entry.id}"}
                      type="button"
                      phx-click="pin-cycle"
                      phx-value-cycle={item.entry.cycle_id}
                      class="inline-flex items-center gap-1 rounded-full border border-sky-400/30 bg-sky-400/10 px-3 py-1 text-[11px] text-sky-100 transition hover:bg-sky-400/20"
                    >
                      <.icon name="hero-arrow-path-rounded-square" class="size-3.5 text-sky-300" />
                      cycle {truncate_id(item.entry.cycle_id, 10)}
                    </button>
                    <button
                      :if={item.entry.span_id}
                      id={"follow-pin-span-#{item.entry.id}"}
                      type="button"
                      phx-click="pin-span"
                      phx-value-span={item.entry.span_id}
                      class="inline-flex items-center gap-1 rounded-full border border-violet-400/30 bg-violet-400/10 px-3 py-1 text-[11px] text-violet-100 transition hover:bg-violet-400/20"
                    >
                      <.icon name="hero-arrows-right-left" class="size-3.5 text-violet-300" />
                      span {truncate_id(item.entry.span_id, 10)}
                    </button>
                    <span
                      :if={item.entry.parent_id}
                      class="inline-flex items-center gap-1 rounded-full border border-zinc-700 bg-zinc-900/60 px-3 py-1 text-[11px] text-zinc-400"
                    >
                      <.icon name="hero-arrow-turn-down-right" class="size-3.5 text-zinc-500" />
                      parent {truncate_id(item.entry.parent_id, 10)}
                    </span>
                  </div>

                  <div
                    :if={item.expanded?}
                    id={"follow-entry-detail-#{item.entry.id}"}
                    class="mt-4 border-t border-zinc-800/80 pt-4"
                  >
                    <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
                      <p class="text-[10px] uppercase tracking-[0.2em] text-zinc-500">Full payload</p>
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

          <div id="tool-feed-end"></div>
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
    visible_entries =
      socket.assigns.entries
      |> visible_entries(
        socket.assigns.follow_filter,
        socket.assigns.filter_text,
        socket.assigns.view_mode
      )

    stream_items = build_stream_items(visible_entries, socket.assigns.expanded_entry_id)

    socket
    |> assign(:entry_count, length(stream_items))
    |> stream(:entries, stream_items, reset: true)
  end

  defp visible_entries(entries, %Filter{} = follow_filter, text_filter, mode) do
    Enum.filter(entries, fn entry ->
      Filter.matches?(entry, follow_filter) and
        matches_text?(entry, text_filter) and
        Entry.visible?(entry, mode)
    end)
  end

  defp build_stream_items(entries, expanded_entry_id) do
    {items, _previous} =
      Enum.map_reduce(entries, nil, fn entry, previous_entry ->
        item = %{
          dom_id: "follow-entry-#{entry_id(entry)}",
          entry: entry,
          expanded?: entry_id(entry) == expanded_entry_id,
          group_break?: group_key(entry) != group_key(previous_entry),
          group_kind: group_kind(entry),
          group_label: group_label(entry)
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

  defp entry_title(entry, :raw), do: entry.event

  defp entry_title(%Entry{family: "tool", scope: scope, summary: summary}, mode)
       when mode in [:smart, :errors],
       do: join_sentence([scope, summary])

  defp entry_title(%Entry{family: "llm", scope: scope, summary: summary}, mode)
       when mode in [:smart, :errors],
       do: join_sentence([scope, summary])

  defp entry_title(%Entry{family: "cycle", cycle_id: cycle_id, summary: summary}, mode)
       when mode in [:smart, :errors],
       do: join_sentence(["cycle #{truncate_id(cycle_id, 10)}", summary])

  defp entry_title(%Entry{family: "think", cycle_id: cycle_id, summary: summary}, mode)
       when mode in [:smart, :errors],
       do: join_sentence(["cycle #{truncate_id(cycle_id, 10)}", summary])

  defp entry_title(%Entry{family: "control", cycle_id: cycle_id, summary: summary}, mode)
       when mode in [:smart, :errors],
       do: join_sentence(["cycle #{truncate_id(cycle_id, 10)}", summary])

  defp entry_title(%Entry{family: "telegram", summary: summary, scope: scope}, mode)
       when mode in [:smart, :errors],
       do: join_sentence([scope, summary])

  defp entry_title(%Entry{scope: scope, summary: summary}, mode) when mode in [:smart, :errors],
    do: join_sentence([scope, summary])

  defp entry_subtitle(entry, :raw) do
    join_sentence([
      raw_measurements(entry.measurements),
      raw_metadata(entry.metadata)
    ])
  end

  defp entry_subtitle(%Entry{} = entry, mode) when mode in [:smart, :errors] do
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

        :smart ->
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
    do: "rounded-full border border-amber-400/20 bg-amber-400/10 px-3 py-1 text-amber-100"

  defp group_label_class(:llm),
    do: "rounded-full border border-emerald-400/20 bg-emerald-400/10 px-3 py-1 text-emerald-100"

  defp group_label_class(:telegram),
    do: "rounded-full border border-violet-400/20 bg-violet-400/10 px-3 py-1 text-violet-100"

  defp group_label_class(_),
    do: "rounded-full border border-zinc-700 bg-zinc-900/70 px-3 py-1 text-zinc-300"

  defp entry_container_class(family, expanded?) do
    [
      "overflow-hidden rounded-3xl border px-4 py-4 shadow-[0_18px_45px_rgba(0,0,0,0.28)] transition md:px-5",
      family_surface_class(family),
      expanded? && "ring-1 ring-inset ring-zinc-200/8"
    ]
  end

  defp summary_class(:error), do: "text-[13px] font-semibold leading-5 text-rose-200"
  defp summary_class(:warn), do: "text-[13px] font-semibold leading-5 text-amber-100"
  defp summary_class(:info), do: "text-[13px] font-semibold leading-5 text-zinc-50"
  defp summary_class(:debug), do: "text-[13px] font-semibold leading-5 text-zinc-300"

  defp family_badge_class(family) do
    [
      "inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.16em]",
      family_badge_palette(family)
    ]
  end

  defp icon_wrap_class(family) do
    [
      "mt-0.5 inline-flex size-9 shrink-0 items-center justify-center rounded-2xl border",
      family_icon_wrap_palette(family)
    ]
  end

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

  defp entry_icon(family) do
    case family do
      "control" ->
        "hero-bolt"

      "message" ->
        "hero-envelope"

      _ ->
        case family_group_key(family) do
          :agent -> "hero-sparkles"
          :tool -> "hero-wrench-screwdriver"
          :llm -> "hero-cpu-chip"
          :telegram -> "hero-chat-bubble-left-right"
          :system -> "hero-circle-stack"
        end
    end
  end

  defp family_surface_class(family) do
    case family_group_key(family) do
      :agent -> "border-sky-500/20 bg-sky-950/20"
      :tool -> "border-amber-500/20 bg-amber-950/20"
      :llm -> "border-emerald-500/20 bg-emerald-950/20"
      :telegram -> "border-violet-500/20 bg-violet-950/20"
      :system -> "border-zinc-800 bg-zinc-950/80"
    end
  end

  defp family_badge_palette(family) do
    case family_group_key(family) do
      :agent -> "border-sky-400/25 bg-sky-400/10 text-sky-100"
      :tool -> "border-amber-400/25 bg-amber-400/10 text-amber-100"
      :llm -> "border-emerald-400/25 bg-emerald-400/10 text-emerald-100"
      :telegram -> "border-violet-400/25 bg-violet-400/10 text-violet-100"
      :system -> "border-zinc-700 bg-zinc-900/80 text-zinc-300"
    end
  end

  defp family_icon_wrap_palette(family) do
    case family_group_key(family) do
      :agent -> "border-sky-400/20 bg-sky-400/10 text-sky-200"
      :tool -> "border-amber-400/20 bg-amber-400/10 text-amber-200"
      :llm -> "border-emerald-400/20 bg-emerald-400/10 text-emerald-200"
      :telegram -> "border-violet-400/20 bg-violet-400/10 text-violet-200"
      :system -> "border-zinc-700 bg-zinc-900/80 text-zinc-300"
    end
  end

  defp family_group_key(family) when family in ["cycle", "think", "control", "message"],
    do: :agent

  defp family_group_key("tool"), do: :tool
  defp family_group_key("llm"), do: :llm
  defp family_group_key("telegram"), do: :telegram
  defp family_group_key(_), do: :system
end
