defmodule FrothWeb.TelemetryLive do
  use FrothWeb, :live_view

  import Ecto.Query

  alias Froth.Follow.{Entry, Projector}

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

    events = load_recent_events(nil, nil)

    {:ok,
     assign(socket,
       entries: events,
       filter_event: nil,
       filter_text: "",
       paused: false,
       view_mode: :smart
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
    filter = if event_prefix == "", do: nil, else: event_prefix
    events = load_recent_events(filter, nil)
    {:noreply, assign(socket, filter_event: filter, filter_text: "", entries: events)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    text = if q == "", do: nil, else: q
    events = load_recent_events(socket.assigns.filter_event, text)
    {:noreply, assign(socket, filter_text: q || "", entries: events)}
  end

  def handle_event("toggle-pause", _, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  def handle_event("set-mode", %{"mode" => mode}, socket) do
    view_mode = if mode == "raw", do: :raw, else: :smart
    {:noreply, assign(socket, view_mode: view_mode)}
  end

  def handle_event("clear", _, socket) do
    {:noreply, assign(socket, entries: [])}
  end

  defp load_recent_events(event_filter, text_filter) do
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
      case event_filter do
        nil -> query
        prefix -> from(e in query, where: like(e.event, ^"#{prefix}%"))
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
              {length(visible_entries(@entries, @filter_event, @view_mode))} entries
            </span>
          </div>
        </div>

        <div class="mb-4 flex flex-wrap items-center gap-2">
          <button
            :for={{prefix, label} <- event_categories()}
            phx-click="filter"
            phx-value-event={prefix}
            class={"rounded-full px-3 py-1 text-xs font-medium transition " <>
              if((@filter_event || "") == prefix,
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
              <tr
                :for={entry <- visible_entries(@entries, @filter_event, @view_mode)}
                id={"event-#{entry.id}"}
                class="border-b border-zinc-900 hover:bg-zinc-900/50"
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
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp visible_entries(entries, prefix, mode) do
    entries
    |> Enum.filter(fn entry ->
      (is_nil(prefix) or String.starts_with?(entry.event, prefix)) and Entry.visible?(entry, mode)
    end)
  end
end
