defmodule FrothWeb.TelemetryLive do
  use FrothWeb, :live_view

  import Ecto.Query

  alias Froth.Follow.{Entry, Filter, Projector}

  @page_size 3000
  @max_events 5000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :telemetry.attach_many(
        "telemetry-live-#{inspect(self())}",
        Froth.Telemetry.events(),
        &__MODULE__.handle_telemetry_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     assign(socket,
       entries: [],
       filter_text: "",
       follow_filter: Filter.new(),
       paused: false,
       selected_entry_id: nil,
       view_mode: :smart
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    follow_filter = filter_from_params(params)
    filter_text = normalize_filter_value(params["q"])
    view_mode = parse_view_mode(params["mode"])
    events = load_recent_events(follow_filter, filter_text)

    {:noreply,
     assign(socket,
       entries: events,
       filter_text: filter_text || "",
       follow_filter: follow_filter,
       selected_entry_id: nil,
       view_mode: view_mode
     )}
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("telemetry-live-#{inspect(self())}")
    :ok
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      entry = Projector.from_live(event_name, measurements, metadata)
      entries = [entry | socket.assigns.entries] |> Enum.take(@max_events)
      {:noreply, assign(socket, entries: entries)}
    end
  end

  @impl true
  def handle_event("filter", %{"event" => event_prefix}, socket) do
    {:noreply, push_patch(socket, to: telemetry_path(socket, event: event_prefix))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: telemetry_path(socket, q: q))}
  end

  def handle_event("toggle-pause", _, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  def handle_event("filter-cycle", %{"cycle" => cycle_id}, socket) do
    {:noreply, push_patch(socket, to: telemetry_path(socket, cycle: cycle_id))}
  end

  def handle_event("filter-span", %{"span" => span_id}, socket) do
    {:noreply, push_patch(socket, to: telemetry_path(socket, span: span_id))}
  end

  def handle_event("clear-scope", _, socket) do
    {:noreply, push_patch(socket, to: telemetry_path(socket, cycle: nil, span: nil))}
  end

  def handle_event("select-entry", %{"id" => id}, socket) do
    selected_entry_id = if socket.assigns.selected_entry_id == id, do: nil, else: id
    {:noreply, assign(socket, selected_entry_id: selected_entry_id)}
  end

  def handle_event("set-mode", %{"mode" => mode}, socket) do
    {:noreply, push_patch(socket, to: telemetry_path(socket, mode: mode))}
  end

  def handle_event("clear", _, socket) do
    {:noreply, assign(socket, entries: [])}
  end

  defp load_recent_events(%Filter{} = follow_filter, text_filter) do
    query =
      from(e in "telemetry_events",
        order_by: [desc: e.inserted_at],
        limit: ^@page_size,
        select: %{
          id: type(e.id, Ecto.UUID),
          event: e.event,
          span_id: e.span_id,
          parent_id: e.parent_id,
          measurements: e.measurements,
          metadata: e.metadata,
          inserted_at: e.inserted_at
        }
      )

    query =
      case follow_filter.event_prefix do
        nil -> query
        prefix -> from(e in query, where: like(e.event, ^"#{prefix}%"))
      end

    query =
      case follow_filter.cycle_id do
        nil ->
          query

        cycle_id ->
          from(e in query,
            where: fragment("?->>'cycle_id' LIKE ?", e.metadata, ^"#{cycle_id}%")
          )
      end

    query =
      case follow_filter.span_id do
        nil ->
          query

        span_id ->
          from(e in query,
            where:
              like(e.span_id, ^"#{span_id}%") or
                fragment("?->>'span_id' LIKE ?", e.metadata, ^"#{span_id}%")
          )
      end

    query =
      case text_filter do
        nil ->
          query

        text ->
          pattern = "%#{text}%"

          from(e in query,
            where:
              like(e.event, ^pattern) or
                fragment("?::text LIKE ?", e.metadata, ^pattern)
          )
      end

    query
    |> Froth.Repo.all(log: false)
    |> Enum.map(&Projector.from_row/1)
  end

  defp event_color("froth.telegram." <> _), do: "text-blue-400"
  defp event_color("froth.agent." <> _), do: "text-purple-400"
  defp event_color("froth.http." <> _), do: "text-amber-400"
  defp event_color("froth.llm." <> _), do: "text-lime-400"
  defp event_color("froth.anthropic." <> _), do: "text-orange-400"
  defp event_color("froth.openai." <> _), do: "text-sky-400"
  defp event_color("froth.grok." <> _), do: "text-fuchsia-400"
  defp event_color("froth.gemini." <> _), do: "text-yellow-300"
  defp event_color("froth.codex." <> _), do: "text-emerald-400"
  defp event_color("froth.qwen." <> _), do: "text-pink-400"
  defp event_color("froth.tasks." <> _), do: "text-cyan-400"
  defp event_color(_), do: "text-zinc-400"

  defp event_categories do
    [
      {"", "All"},
      {"froth.telegram.", "Telegram"},
      {"froth.agent.", "Agent"},
      {"froth.http.", "HTTP"},
      {"froth.llm.", "LLM"},
      {"froth.anthropic.", "Anthropic"},
      {"froth.openai.", "OpenAI"},
      {"froth.grok.", "Grok"},
      {"froth.gemini.", "Gemini"},
      {"froth.codex.", "Codex"},
      {"froth.qwen.", "Qwen"},
      {"froth.tasks.", "Tasks"}
    ]
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%H:%M:%S")
  end

  defp format_time(_), do: ""

  defp format_metadata(meta) when is_map(meta) and map_size(meta) == 0, do: nil
  defp format_metadata(meta) when not is_map(meta), do: nil

  defp format_metadata(meta) when is_map(meta) do
    meta
    |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
    |> Enum.map(fn {k, v} ->
      val = format_value(v)
      "#{k}=#{val}"
    end)
    |> Enum.join(" ")
  end

  defp format_value(v) when is_binary(v) do
    if String.length(v) > 80, do: String.slice(v, 0, 80) <> "…", else: v
  end

  defp format_value(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)

  defp format_value(v) when is_map(v) or is_list(v),
    do: inspect(v, limit: 10, printable_limit: 80)

  defp format_value(v), do: inspect(v, limit: 10, printable_limit: 80)

  defp short_event(event) do
    event
    |> String.replace_prefix("froth.", "")
  end

  defp family_color("telegram"), do: "text-blue-400"
  defp family_color("cycle"), do: "text-sky-300"
  defp family_color("think"), do: "text-cyan-300"
  defp family_color("tool"), do: "text-emerald-300"
  defp family_color("llm"), do: "text-fuchsia-300"
  defp family_color("task"), do: "text-amber-300"
  defp family_color("transport"), do: "text-zinc-500"
  defp family_color(_), do: "text-zinc-300"

  defp summary_color(:error), do: "text-red-300"
  defp summary_color(:warn), do: "text-yellow-200"
  defp summary_color(:info), do: "text-zinc-100"
  defp summary_color(:debug), do: "text-zinc-400"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="min-h-screen bg-zinc-950 mx-auto max-w-7xl px-4 py-6">
        <div class="mb-4 flex items-center justify-between">
          <h1 class="text-xl font-semibold text-zinc-100">Telemetry Events</h1>
          <div class="flex items-center gap-2">
            <button
              id="telemetry-mode-smart"
              phx-click="set-mode"
              phx-value-mode="smart"
              class={"rounded px-3 py-1.5 text-xs font-medium " <>
                if(@view_mode == :smart,
                  do: "bg-zinc-100 text-zinc-900",
                  else: "bg-zinc-700 text-zinc-300 hover:bg-zinc-600"
                )}
            >
              Smart
            </button>
            <button
              id="telemetry-mode-raw"
              phx-click="set-mode"
              phx-value-mode="raw"
              class={"rounded px-3 py-1.5 text-xs font-medium " <>
                if(@view_mode == :raw,
                  do: "bg-zinc-100 text-zinc-900",
                  else: "bg-zinc-700 text-zinc-300 hover:bg-zinc-600"
                )}
            >
              Raw
            </button>
            <button
              id="telemetry-toggle-pause"
              phx-click="toggle-pause"
              class={"rounded px-3 py-1.5 text-xs font-medium #{if @paused, do: "bg-amber-600 text-white", else: "bg-zinc-700 text-zinc-300 hover:bg-zinc-600"}"}
            >
              {if @paused, do: "▶ Resume", else: "⏸ Pause"}
            </button>
            <button
              id="telemetry-clear"
              phx-click="clear"
              class="rounded bg-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:bg-zinc-600"
            >
              Clear
            </button>
            <span class="text-xs text-zinc-500">
              {length(visible_entries(@entries, @follow_filter, @filter_text, @view_mode))} entries
            </span>
          </div>
        </div>

        <div class="mb-4 flex flex-wrap items-center gap-2">
          <button
            :for={{prefix, label} <- event_categories()}
            phx-click="filter"
            phx-value-event={prefix}
            class={"rounded-full px-3 py-1 text-xs font-medium transition " <>
              if((@follow_filter.event_prefix || "") == prefix,
                do: "bg-zinc-100 text-zinc-900",
                else: "bg-zinc-800 text-zinc-400 hover:bg-zinc-700 hover:text-zinc-200"
              )}
          >
            {label}
          </button>
          <form id="telemetry-search" phx-change="search" class="ml-auto">
            <input
              id="telemetry-search-input"
              type="text"
              name="q"
              value={@filter_text}
              placeholder="Search metadata..."
              phx-debounce="300"
              class="rounded bg-zinc-800 px-3 py-1.5 text-xs text-zinc-200 placeholder-zinc-500 border border-zinc-700 focus:border-zinc-500 focus:outline-none w-48"
            />
          </form>
        </div>

        <div
          :if={@follow_filter.cycle_id || @follow_filter.span_id}
          id="telemetry-scope-filters"
          class="mb-4 flex flex-wrap items-center gap-2"
        >
          <span
            :if={@follow_filter.cycle_id}
            class="rounded-full border border-sky-500/40 bg-sky-500/10 px-3 py-1 text-xs font-medium text-sky-200"
          >
            cycle {@follow_filter.cycle_id}
          </span>
          <span
            :if={@follow_filter.span_id}
            class="rounded-full border border-fuchsia-500/40 bg-fuchsia-500/10 px-3 py-1 text-xs font-medium text-fuchsia-200"
          >
            span {@follow_filter.span_id}
          </span>
          <button
            id="telemetry-clear-scope"
            phx-click="clear-scope"
            class="rounded-full bg-zinc-800 px-3 py-1 text-xs font-medium text-zinc-300 hover:bg-zinc-700 hover:text-zinc-100"
          >
            Clear scope
          </button>
        </div>

        <div class="rounded-xl border border-zinc-800 bg-zinc-950 overflow-hidden">
          <table id="telemetry-table" class="w-full text-xs">
            <thead>
              <tr class="border-b border-zinc-800 text-left text-zinc-500">
                <th class="px-3 py-2 w-20">Time</th>
                <%= if @view_mode == :raw do %>
                  <th class="px-3 py-2">Event</th>
                  <th class="px-3 py-2 w-24">Span</th>
                  <th class="px-3 py-2">Details</th>
                <% else %>
                  <th class="px-3 py-2 w-24">Family</th>
                  <th class="px-3 py-2 w-28">Scope</th>
                  <th class="px-3 py-2">Summary</th>
                  <th class="px-3 py-2">Detail</th>
                <% end %>
              </tr>
            </thead>
            <tbody id="events">
              <%= for entry <- visible_entries(@entries, @follow_filter, @filter_text, @view_mode) do %>
                <tr
                  id={"event-#{entry.id}"}
                  phx-click="select-entry"
                  phx-value-id={entry.id}
                  class={[
                    "cursor-pointer border-b border-zinc-900 hover:bg-zinc-900/50",
                    @selected_entry_id == to_string(entry.id) && "bg-zinc-900/60"
                  ]}
                >
                  <td class="px-3 py-1.5 font-mono text-zinc-500 whitespace-nowrap">
                    {format_time(entry.at)}
                  </td>
                  <%= if @view_mode == :raw do %>
                    <td class={"px-3 py-1.5 font-mono whitespace-nowrap #{event_color(entry.event)}"}>
                      {short_event(entry.event)}
                    </td>
                    <td class="px-3 py-1.5 font-mono text-zinc-600 whitespace-nowrap">
                      <%= if sid = entry.span_id do %>
                        <span class="text-zinc-500" title={"span: #{sid}"}>
                          {String.slice(sid, 0, 8)}
                        </span>
                      <% end %>
                      <%= if pid = entry.parent_id do %>
                        <span class="text-zinc-600" title={"parent: #{pid}"}>
                          ← {String.slice(to_string(pid), 0, 8)}
                        </span>
                      <% end %>
                    </td>
                    <td
                      class="px-3 py-1.5 text-zinc-400 truncate max-w-lg"
                      title={format_metadata(entry.metadata)}
                    >
                      {format_metadata(entry.metadata) || ""}
                    </td>
                  <% else %>
                    <td class={"px-3 py-1.5 font-mono whitespace-nowrap #{family_color(entry.family)}"}>
                      {entry.family}
                    </td>
                    <td class="px-3 py-1.5 font-mono text-zinc-500 whitespace-nowrap">
                      {entry.scope || "-"}
                    </td>
                    <td class={"px-3 py-1.5 truncate max-w-sm #{summary_color(entry.level)}"}>
                      {entry.summary}
                    </td>
                    <td class="px-3 py-1.5 text-zinc-400 truncate max-w-lg" title={entry.detail || ""}>
                      {entry.detail || ""}
                    </td>
                  <% end %>
                </tr>
                <%= if @selected_entry_id == to_string(entry.id) do %>
                  <tr id={"event-detail-#{entry.id}"} class="border-b border-zinc-900 bg-zinc-900/80">
                    <td colspan="5" class="px-3 py-3">
                      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
                        <div class="text-[11px] uppercase tracking-[0.2em] text-zinc-500">
                          Raw Event Payload
                        </div>
                        <div class="text-[11px] text-zinc-600">{entry.event}</div>
                      </div>
                      <div class="mb-3 flex flex-wrap items-center gap-2">
                        <button
                          :if={entry.cycle_id}
                          id={"event-filter-cycle-#{entry.id}"}
                          phx-click="filter-cycle"
                          phx-value-cycle={entry.cycle_id}
                          class="rounded-full border border-sky-500/40 bg-sky-500/10 px-3 py-1 text-[11px] font-medium text-sky-200 hover:bg-sky-500/20"
                        >
                          Filter cycle {String.slice(entry.cycle_id, 0, 8)}
                        </button>
                        <button
                          :if={entry.span_id}
                          id={"event-filter-span-#{entry.id}"}
                          phx-click="filter-span"
                          phx-value-span={entry.span_id}
                          class="rounded-full border border-fuchsia-500/40 bg-fuchsia-500/10 px-3 py-1 text-[11px] font-medium text-fuchsia-200 hover:bg-fuchsia-500/20"
                        >
                          Filter span {String.slice(entry.span_id, 0, 8)}
                        </button>
                      </div>
                      <pre
                        id={"event-json-#{entry.id}"}
                        phx-no-curly-interpolation
                        class="overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-950 p-3 font-mono text-[11px] leading-5 text-zinc-300"
                      ><%= entry_json(entry) %></pre>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp visible_entries(entries, %Filter{} = follow_filter, text_filter, mode) do
    entries
    |> Enum.filter(fn entry ->
      Filter.matches?(entry, follow_filter) and matches_text?(entry, text_filter) and
        Entry.visible?(entry, mode)
    end)
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
        inspect(entry.metadata, pretty: false, printable_limit: 400, limit: 20)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join("\n")

    String.contains?(haystack, needle)
  end

  defp normalize_filter_value(nil), do: nil

  defp normalize_filter_value(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp filter_from_params(params) do
    Filter.new(
      event_prefix: params["event"],
      cycle_id: params["cycle"],
      span_id: params["span"]
    )
  end

  defp parse_view_mode("raw"), do: :raw
  defp parse_view_mode(_), do: :smart

  defp telemetry_path(socket, overrides) do
    params =
      %{
        "event" => socket.assigns.follow_filter.event_prefix,
        "cycle" => socket.assigns.follow_filter.cycle_id,
        "span" => socket.assigns.follow_filter.span_id,
        "q" => normalize_filter_value(socket.assigns.filter_text),
        "mode" => mode_param(socket.assigns.view_mode)
      }
      |> merge_query_overrides(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    ~p"/froth/telemetry?#{params}"
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
  defp mode_param(:smart), do: nil

  defp entry_json(entry) do
    %{
      id: entry.id,
      event: entry.event,
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
      metadata: entry.metadata
    }
    |> Jason.encode_to_iodata!()
    |> Jason.Formatter.pretty_print()
  end
end
