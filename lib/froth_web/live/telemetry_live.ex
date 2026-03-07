defmodule FrothWeb.TelemetryLive do
  use FrothWeb, :live_view

  import Ecto.Query

  @page_size 100
  @max_events 500

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
       events: events,
       filter_event: nil,
       filter_text: "",
       paused: false
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
      event = %{
        id: System.unique_integer([:positive]),
        event: Enum.join(event_name, "."),
        measurements: measurements,
        metadata: clean_metadata(metadata),
        inserted_at: DateTime.utc_now()
      }

      events = [event | socket.assigns.events] |> Enum.take(@max_events)

      events =
        case socket.assigns.filter_event do
          nil -> events
          _ -> events
        end

      {:noreply, assign(socket, events: events)}
    end
  end

  @impl true
  def handle_event("filter", %{"event" => event_prefix}, socket) do
    filter = if event_prefix == "", do: nil, else: event_prefix
    events = load_recent_events(filter, nil)
    {:noreply, assign(socket, filter_event: filter, filter_text: "", events: events)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    text = if q == "", do: nil, else: q
    events = load_recent_events(socket.assigns.filter_event, text)
    {:noreply, assign(socket, filter_text: q || "", events: events)}
  end

  def handle_event("toggle-pause", _, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  def handle_event("clear", _, socket) do
    {:noreply, assign(socket, events: [])}
  end

  defp load_recent_events(event_filter, text_filter) do
    query =
      from(e in "telemetry_events",
        order_by: [desc: e.inserted_at],
        limit: ^@page_size,
        select: %{
          id: e.id,
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

    Froth.Repo.all(query, log: false)
  end

  defp clean_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([:span_id, :parent_id])
    |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp clean_metadata(other), do: %{"value" => inspect(other)}

  defp safe_value(v) when is_binary(v), do: v
  defp safe_value(v) when is_number(v), do: v
  defp safe_value(v) when is_boolean(v), do: v
  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v), do: inspect(v, limit: 20, printable_limit: 200)

  defp event_color("froth.telegram." <> _), do: "text-blue-400"
  defp event_color("froth.agent." <> _), do: "text-purple-400"
  defp event_color("froth.http." <> _), do: "text-amber-400"
  defp event_color("froth.anthropic." <> _), do: "text-orange-400"
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
      {"froth.anthropic.", "Anthropic"},
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

  defp format_metadata(meta) when is_map(meta) do
    meta
    |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
    |> Enum.map(fn {k, v} ->
      val = if is_binary(v) and String.length(v) > 80, do: String.slice(v, 0, 80) <> "…", else: v
      "#{k}=#{val}"
    end)
    |> Enum.join(" ")
  end

  defp format_metadata(_), do: nil

  defp short_event(event) do
    event
    |> String.replace_prefix("froth.", "")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="min-h-screen bg-zinc-950 mx-auto max-w-7xl px-4 py-6">
        <div class="mb-4 flex items-center justify-between">
          <h1 class="text-xl font-semibold text-zinc-100">Telemetry Events</h1>
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle-pause"
              class={"rounded px-3 py-1.5 text-xs font-medium #{if @paused, do: "bg-amber-600 text-white", else: "bg-zinc-700 text-zinc-300 hover:bg-zinc-600"}"}
            >
              {if @paused, do: "▶ Resume", else: "⏸ Pause"}
            </button>
            <button
              phx-click="clear"
              class="rounded bg-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:bg-zinc-600"
            >
              Clear
            </button>
            <span class="text-xs text-zinc-500">{length(@events)} events</span>
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
          <form phx-change="search" class="ml-auto">
            <input
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
          <table class="w-full text-xs">
            <thead>
              <tr class="border-b border-zinc-800 text-left text-zinc-500">
                <th class="px-3 py-2 w-20">Time</th>
                <th class="px-3 py-2">Event</th>
                <th class="px-3 py-2 w-24">Span</th>
                <th class="px-3 py-2">Details</th>
              </tr>
            </thead>
            <tbody id="events">
              <tr
                :for={event <- visible_events(@events, @filter_event)}
                id={"event-#{event.id}"}
                class="border-b border-zinc-900 hover:bg-zinc-900/50"
              >
                <td class="px-3 py-1.5 font-mono text-zinc-500 whitespace-nowrap">
                  {format_time(event.inserted_at)}
                </td>
                <td class={"px-3 py-1.5 font-mono whitespace-nowrap #{event_color(event.event)}"}>
                  {short_event(event.event)}
                </td>
                <td class="px-3 py-1.5 font-mono text-zinc-600 whitespace-nowrap">
                  <%= if sid = event[:span_id] || event.metadata["span_id"] do %>
                    <span class="text-zinc-500" title={"span: #{sid}"}>{String.slice(sid, 0, 8)}</span>
                  <% end %>
                  <%= if pid = event[:parent_id] || event.metadata["parent_id"] do %>
                    <span class="text-zinc-600" title={"parent: #{pid}"}>← {String.slice(to_string(pid), 0, 8)}</span>
                  <% end %>
                </td>
                <td class="px-3 py-1.5 text-zinc-400 truncate max-w-lg" title={format_metadata(event.metadata)}>
                  {format_metadata(event.metadata) || ""}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp visible_events(events, nil), do: events

  defp visible_events(events, prefix) do
    Enum.filter(events, fn e -> String.starts_with?(e.event, prefix) end)
  end
end
