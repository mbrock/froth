defmodule FrothWeb.FollowLive do
  use FrothWeb, :live_view

  alias Froth.Follow.{Entry, Filter, Source}

  @page_size 3000
  @max_entries 5000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Froth.PubSub, "events")
    end

    {:ok,
     socket
     |> assign(:entries, [])
     |> assign(:entry_count, 0)
     |> assign(:selected_entry_id, nil)
     |> assign(:selected_entry, nil)
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
     |> assign(:selected_entry_id, nil)
     |> assign(:selected_entry, nil)
     |> assign(:filter_text, filter_text)
     |> assign(:follow_filter, follow_filter)
     |> assign(:search_form, search_form(filter_text))
     |> assign(:view_mode, view_mode)
     |> sync_entries()}
  end

  @impl true
  def handle_info({:event, %Froth.Event{} = event}, socket) do
    entry = Entry.from_event(event)

    if matches_entry?(
         entry,
         socket.assigns.follow_filter,
         socket.assigns.filter_text
       ) do
      entries =
        socket.assigns.entries
        |> Kernel.++([entry])
        |> Enum.take(-@max_entries)

      {:noreply,
       socket
       |> assign(:entries, entries)
       |> sync_entries()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"filters" => %{"q" => q}}, socket) do
    {:noreply,
     push_patch(socket, to: follow_path(socket, q: q), replace: true)}
  end

  def handle_event("set-mode", %{"mode" => mode}, socket) do
    {:noreply, push_patch(socket, to: follow_path(socket, mode: mode))}
  end

  def handle_event("select-entry", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_entry_id, id)
     |> sync_entries()}
  end

  def handle_event("follow-latest", _, socket) do
    {:noreply,
     socket
     |> assign(:selected_entry_id, nil)
     |> sync_entries()
     |> push_event("follow-scroll", %{})}
  end

  def handle_event("pin-cycle", %{"cycle" => cycle_id}, socket) do
    {:noreply,
     push_patch(socket, to: follow_path(socket, cycle: cycle_id, span: nil))}
  end

  def handle_event("pin-span", %{"span" => span_id}, socket) do
    {:noreply,
     push_patch(socket, to: follow_path(socket, cycle: nil, span: span_id))}
  end

  def handle_event("clear-scope", _, socket) do
    {:noreply,
     push_patch(socket, to: follow_path(socket, cycle: nil, span: nil))}
  end

  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(:entries, [])
     |> assign(:selected_entry_id, nil)
     |> assign(:selected_entry, nil)
     |> sync_entries()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div
        id="follow-reader"
        phx-hook="ToolScroll"
        data-follow-mode="smart"
        class="flex min-h-[100dvh] flex-col overflow-hidden bg-black pt-[env(safe-area-inset-top)] font-mono text-zinc-100"
      >
        <div class="border-b border-white/10 px-2 py-1.5 sm:px-3">
          <div class="flex flex-wrap items-center gap-2">
            <.form
              for={@search_form}
              id="follow-search-form"
              phx-change="search"
              class="min-w-0 flex-1 basis-full sm:basis-[18rem]"
            >
              <.input
                field={@search_form[:q]}
                type="text"
                id="follow-search-input"
                class="block w-full border border-white/10 bg-black px-2 py-1 text-[12px] leading-5 text-zinc-100 placeholder:text-zinc-500 focus:border-white/30 focus:outline-none"
                phx-debounce="150"
                placeholder="search event, metadata"
              />
            </.form>

            <button
              id="follow-mode-smart"
              type="button"
              phx-click="set-mode"
              phx-value-mode="smart"
              data-active={@view_mode == :smart}
              class={mode_button_class(@view_mode, :smart)}
            >
              all
            </button>
            <button
              id="follow-mode-errors"
              type="button"
              phx-click="set-mode"
              phx-value-mode="errors"
              data-active={@view_mode == :errors}
              class={mode_button_class(@view_mode, :errors)}
            >
              errors
            </button>

            <button
              id="follow-latest"
              type="button"
              phx-click="follow-latest"
              class="appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-[11px] uppercase tracking-[0.18em] text-zinc-400 transition hover:text-zinc-100"
            >
              latest
            </button>
            <button
              id="follow-clear"
              type="button"
              phx-click="clear"
              class="appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-[11px] uppercase tracking-[0.18em] text-zinc-400 transition hover:text-zinc-100"
            >
              clear
            </button>

            <div class="ml-auto text-[11px] uppercase tracking-[0.2em] text-zinc-500">
              {@entry_count} visible
            </div>
          </div>

          <div
            :if={@follow_filter.cycle_id || @follow_filter.span_id}
            class="mt-1.5 flex flex-wrap items-center gap-2 text-[10px] uppercase tracking-[0.18em] text-zinc-500"
          >
            <span>scope</span>
            <%= if @follow_filter.cycle_id do %>
              <span class="text-zinc-300">
                cycle {truncate_id(@follow_filter.cycle_id, 12)}
              </span>
            <% end %>
            <%= if @follow_filter.span_id do %>
              <span class="text-zinc-300">
                span {truncate_id(@follow_filter.span_id, 12)}
              </span>
            <% end %>
            <button
              id="follow-clear-scope"
              type="button"
              phx-click="clear-scope"
              class="appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-zinc-400 transition hover:text-zinc-100"
            >
              clear scope
            </button>
          </div>
        </div>

        <div
          id="follow-feed"
          class="min-h-0 flex-1 overflow-y-auto"
          data-scroll-body
        >
          <table
            id="follow-entries"
            phx-update="stream"
            class="w-full border-collapse"
          >
            <tbody :if={@entry_count == 0} id="follow-empty-state">
              <tr>
                <td class="px-2 py-3 text-[12px] text-zinc-500">
                  No matching events. Adjust the search or wait for new events.
                </td>
              </tr>
            </tbody>

            <tbody
              :for={{dom_id, item} <- @streams.entries}
              id={dom_id}
              phx-click="select-entry"
              phx-value-id={item.entry.id}
              aria-selected={item.selected?}
              class="cursor-pointer"
            >
              <tr class={[
                "align-top transition-colors",
                item.selected? && "bg-white/[0.04]",
                !item.selected? && "hover:bg-white/[0.02]"
              ]}>
                <td class="w-[8rem] border-b border-white/10 px-2 py-0.5 text-[11px] leading-4 text-zinc-500">
                  {format_time(item.entry.at)}
                </td>
                <td class={[
                  "border-b border-white/10 px-2 py-0.5 text-[11px] leading-4",
                  level_class(item.entry.level)
                ]}>
                  {item.entry.event}
                </td>
                <td class="border-b border-white/10 px-2 py-0.5 text-[10px] leading-4 text-zinc-400">
                  <div :if={item.entry.cycle_id}>
                    <button
                      id={"follow-pin-cycle-#{item.entry.id}"}
                      type="button"
                      phx-click="pin-cycle"
                      phx-value-cycle={item.entry.cycle_id}
                      class="hover:text-zinc-100"
                    >
                      cycle {truncate_id(item.entry.cycle_id, 12)}
                    </button>
                  </div>
                  <div :if={item.entry.span_id}>
                    <button
                      id={"follow-pin-span-#{item.entry.id}"}
                      type="button"
                      phx-click="pin-span"
                      phx-value-span={item.entry.span_id}
                      class="hover:text-zinc-100"
                    >
                      span {truncate_id(item.entry.span_id, 12)}
                    </button>
                  </div>
                </td>
                <td class="border-b border-white/10 px-2 py-0.5 text-[10px] leading-4 text-zinc-400 break-words whitespace-pre-wrap">
                  {metadata_sketch(item.entry.metadata)}
                </td>
                <td class="w-[5rem] border-b border-white/10 px-2 py-0.5 text-right text-[10px] leading-4 text-zinc-500">
                  <div :if={item.entry.duration_ms}>
                    {item.entry.duration_ms}ms
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <div id="follow-feed-end" data-scroll-end></div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_recent_entries(%Filter{} = follow_filter, text_filter) do
    Source.recent_entries(
      filter: follow_filter,
      text: text_filter,
      limit: @page_size
    )
    |> Enum.reverse()
  end

  defp sync_entries(socket) do
    matching =
      socket.assigns.entries
      |> matching_entries(
        socket.assigns.follow_filter,
        socket.assigns.filter_text
      )

    visible =
      Enum.filter(matching, &Entry.visible?(&1, socket.assigns.view_mode))

    selected_entry =
      Enum.find(visible, &(&1.id == socket.assigns.selected_entry_id)) ||
        List.last(visible)

    selected_entry_id = selected_entry && selected_entry.id

    stream_items =
      Enum.map(visible, fn entry ->
        %{
          dom_id: "follow-entry-#{entry.id}",
          entry: entry,
          selected?: entry.id == selected_entry_id
        }
      end)

    socket
    |> assign(:entry_count, length(stream_items))
    |> assign(:selected_entry_id, selected_entry_id)
    |> assign(:selected_entry, selected_entry)
    |> stream(:entries, stream_items, reset: true)
  end

  defp matching_entries(entries, %Filter{} = follow_filter, text_filter) do
    Enum.filter(entries, fn entry ->
      Filter.matches?(entry, follow_filter) and
        matches_text?(entry, text_filter)
    end)
  end

  defp matches_entry?(%Entry{} = entry, %Filter{} = follow_filter, text) do
    Filter.matches?(entry, follow_filter) and matches_text?(entry, text)
  end

  defp matches_text?(_entry, nil), do: true

  defp matches_text?(entry, text) do
    needle = String.downcase(text)

    haystack =
      [
        entry.event,
        inspect(entry.metadata, limit: 20, printable_limit: 400),
        inspect(entry.measurements, limit: 10, printable_limit: 200)
      ]
      |> Enum.map(&String.downcase/1)
      |> Enum.join("\n")

    String.contains?(haystack, needle)
  end

  defp filter_from_params(params) do
    Filter.new(cycle_id: params["cycle"], span_id: params["span"])
  end

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

  defp normalize_query_value(:mode, value),
    do: mode_param(parse_view_mode(value))

  defp normalize_query_value("mode", value),
    do: mode_param(parse_view_mode(value))

  defp normalize_query_value(_key, value), do: normalize_filter_value(value)

  defp mode_param(:errors), do: "errors"
  defp mode_param(_), do: nil

  defp normalize_filter_value(nil), do: nil

  defp normalize_filter_value(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp search_form(filter_text),
    do: to_form(%{"q" => filter_text || ""}, as: :filters)

  defp format_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(%NaiveDateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(_), do: "--:--:--.---"

  defp truncate_id(nil, _max), do: nil

  defp truncate_id(value, max),
    do: value |> to_string() |> String.slice(0, max)

  defp mode_button_class(current_mode, mode) do
    base =
      "appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-[11px] uppercase tracking-[0.18em] transition hover:text-zinc-100"

    active =
      if current_mode == mode,
        do: "text-zinc-50 underline decoration-white/30 underline-offset-4",
        else: "text-zinc-400"

    [base, active]
  end

  defp level_class(:error), do: "text-rose-200"
  defp level_class(:warn), do: "text-amber-100"
  defp level_class(:debug), do: "text-zinc-500"
  defp level_class(_), do: "text-zinc-100"

  # Render a one-line sketch of the metadata, dropping noise keys and
  # truncating long values. Good enough for the UI; the full bag is
  # still on the Entry struct for anyone who wants to click through.
  defp metadata_sketch(metadata) when map_size(metadata) == 0, do: ""

  defp metadata_sketch(metadata) do
    metadata
    |> Map.drop(["system_time", "blob_ref"])
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join(" ", fn {key, value} ->
      "#{key}=#{format_value(value)}"
    end)
    |> String.slice(0, 400)
  end

  defp format_value(value) when is_binary(value) do
    if String.length(value) > 80,
      do: String.slice(value, 0, 80) <> "…",
      else: value
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)

  defp format_value(value) when is_integer(value),
    do: Integer.to_string(value)

  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(nil), do: "nil"
  defp format_value(value), do: inspect(value, limit: 6, printable_limit: 80)
end
