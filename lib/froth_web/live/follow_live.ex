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
  def terminate(_reason, socket) do
    :telemetry.detach(telemetry_handler_id(socket))
    :ok
  end

  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  @impl true
  def handle_info(
        {:telemetry_event, event_name, measurements, metadata},
        socket
      ) do
    entry = Projector.from_live(event_name, measurements, metadata)

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
                placeholder="search event, detail, metadata"
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
              smart
            </button>
            <button
              id="follow-mode-raw"
              type="button"
              phx-click="set-mode"
              phx-value-mode="raw"
              data-active={@view_mode == :raw}
              class={mode_button_class(@view_mode, :raw)}
            >
              raw
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
              <button
                id="follow-scope-cycle"
                type="button"
                phx-click="pin-cycle"
                phx-value-cycle={@follow_filter.cycle_id}
                class="appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-zinc-300 transition hover:text-zinc-100"
              >
                cycle {truncate_id(@follow_filter.cycle_id, 12)}
              </button>
            <% end %>
            <%= if @follow_filter.span_id do %>
              <button
                id="follow-scope-span"
                type="button"
                phx-click="pin-span"
                phx-value-span={@follow_filter.span_id}
                class="appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-zinc-300 transition hover:text-zinc-100"
              >
                span {truncate_id(@follow_filter.span_id, 12)}
              </button>
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
                  No matching entries. Adjust the search, clear scope pinning, or wait for new telemetry.
                </td>
              </tr>
            </tbody>

            <.follow_feed_entry
              :for={{dom_id, item} <- @streams.entries}
              id={dom_id}
              item={item}
              view_mode={@view_mode}
            />
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

  defp follow_feed_entry(assigns) do
    ~H"""
    <% secondary_text = entry_secondary_text(@item.entry, @view_mode) %>
    <% exit_value = exit_code(@item.entry) %>
    <tbody
      id={@id}
      phx-click="select-entry"
      phx-value-id={entry_id(@item.entry)}
      aria-selected={@item.selected?}
      class="cursor-pointer"
    >
      <tr :if={@item.group_break?}>
        <td
          colspan="5"
          class={[
            "border-b border-white/10 px-2 pb-0.5 pt-2 text-[9px] uppercase tracking-[0.22em]",
            group_label_class(group_kind(@item.entry))
          ]}
        >
          {@item.group_label}
        </td>
      </tr>

      <tr class={[
        "align-top transition-colors",
        @item.selected? && "bg-white/[0.04]",
        !@item.selected? && "hover:bg-white/[0.02]"
      ]}>
        <td class="w-[7.25rem] border-b border-white/10 px-2 py-0.5 text-[11px] leading-4 text-zinc-500">
          {format_time(@item.entry.at)}
        </td>
        <td class={[
          "border-b border-white/10 px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] leading-4",
          family_column_palette(@item.entry)
        ]}>
          {family_short_label(@item.entry.family)}
        </td>
        <td class={[
          "border-b border-white/10 px-2 py-0.5 text-[11px] leading-4",
          scope_column_class(@item.entry)
        ]}>
          <div class="flex flex-wrap items-center gap-1">
            <span>{scope_label(@item.entry)}</span>
            <%= if @item.entry.cycle_id do %>
              <button
                id={"follow-pin-cycle-#{@item.entry.id}"}
                type="button"
                phx-click="pin-cycle"
                phx-value-cycle={@item.entry.cycle_id}
                class="text-[10px] uppercase tracking-[0.16em] text-zinc-400 hover:text-zinc-100"
              >
                pin cycle
              </button>
            <% end %>
            <%= if @item.entry.span_id do %>
              <button
                id={"follow-pin-span-#{@item.entry.id}"}
                type="button"
                phx-click="pin-span"
                phx-value-span={@item.entry.span_id}
                class="text-[10px] uppercase tracking-[0.16em] text-zinc-400 hover:text-zinc-100"
              >
                pin span
              </button>
            <% end %>
          </div>
        </td>
        <td class="border-b border-white/10 px-2 py-0.5">
          <div class={summary_class(@item.entry)}>
            {entry_primary_text(@item.entry, @view_mode)}
          </div>
          <div :if={secondary_text} class={secondary_text_class(@item.entry)}>
            {secondary_text}
          </div>
        </td>
        <td class="border-b border-white/10 px-2 py-0.5 text-right text-[10px] leading-4 text-zinc-500">
          <div :if={@item.entry.duration_ms}>{@item.entry.duration_ms}ms</div>
          <div :if={exit_value} class={exit_badge_class(exit_value)}>
            exit {exit_value}
          </div>
        </td>
      </tr>
    </tbody>
    """
  end

  defp sync_entries(socket) do
    matching_entries =
      socket.assigns.entries
      |> matching_entries(
        socket.assigns.follow_filter,
        socket.assigns.filter_text
      )

    visible_entries =
      Enum.filter(
        matching_entries,
        &Entry.visible?(&1, socket.assigns.view_mode)
      )

    selected_entry =
      selected_entry_state(visible_entries, socket.assigns.selected_entry_id)

    selected_entry_id = selected_entry && entry_id(selected_entry)

    stream_items =
      build_stream_items(visible_entries, selected_entry_id)

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

  defp build_stream_items(entries, selected_entry_id) do
    {items, _previous} =
      Enum.map_reduce(entries, nil, fn entry, previous_entry ->
        item = %{
          dom_id: "follow-entry-#{entry_id(entry)}",
          entry: entry,
          selected?: entry_id(entry) == selected_entry_id,
          group_break?: group_key(entry) != group_key(previous_entry),
          group_label: group_label(entry)
        }

        {item, entry}
      end)

    items
  end

  defp matches_entry?(
         %Entry{} = entry,
         %Filter{} = follow_filter,
         text_filter
       ) do
    Filter.matches?(entry, follow_filter) and
      matches_text?(entry, text_filter)
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
        inspect(entry.measurements,
          pretty: false,
          printable_limit: 400,
          limit: 20
        ),
        inspect(entry.metadata,
          pretty: false,
          printable_limit: 400,
          limit: 20
        )
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

  defp normalize_query_value(:mode, value),
    do: mode_param(parse_view_mode(value))

  defp normalize_query_value("mode", value),
    do: mode_param(parse_view_mode(value))

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

  defp search_form(filter_text),
    do: to_form(%{"q" => filter_text || ""}, as: :filters)

  defp telemetry_handler_id(socket),
    do: "follow-live-#{inspect(socket.root_pid || self())}"

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
      raw_context(entry.metadata)
    ])
  end

  defp entry_secondary_text(%Entry{} = entry, mode)
       when mode in [:smart, :errors] do
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

  defp raw_measurements(measurements) when map_size(measurements) == 0,
    do: nil

  defp raw_measurements(measurements) do
    measurements
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
    |> Enum.join(" ")
  end

  defp raw_context(metadata) when map_size(metadata) == 0, do: nil

  defp raw_context(metadata) do
    metadata
    |> Map.drop(["system_time"])
    |> Map.take(
      ~w(provider model cycle_id span_id parent_id tool_use_id message_id result_type op status exit_code reason phase kind scope level)
    )
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
    |> join_sentence()
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)

  defp format_value(value) when is_integer(value),
    do: Integer.to_string(value)

  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(value), do: inspect(value, limit: 10, printable_limit: 80)

  defp truncate_id(nil, _max), do: nil

  defp truncate_id(value, max) do
    value
    |> to_string()
    |> String.slice(0, max)
  end

  defp selected_entry_state(entries, selected_entry_id) do
    selected_entry =
      Enum.find(entries, &(entry_id(&1) == selected_entry_id)) ||
        List.last(entries)

    selected_entry
  end

  defp scope_label(%Entry{scope: scope}) when is_binary(scope), do: scope

  defp scope_label(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id),
    do: "cycle #{truncate_id(cycle_id, 12)}"

  defp scope_label(%Entry{span_id: span_id}) when is_binary(span_id),
    do: "span #{truncate_id(span_id, 12)}"

  defp scope_label(%Entry{}), do: "-"

  defp mode_button_class(current_mode, mode) do
    base =
      "appearance-none border-0 bg-transparent p-0 font-[inherit] cursor-pointer text-[11px] uppercase tracking-[0.18em] transition hover:text-zinc-100"

    active =
      case {current_mode, mode} do
        {:smart, :smart} ->
          "text-zinc-50 underline decoration-white/30 underline-offset-4"

        {:raw, :raw} ->
          "text-zinc-50 underline decoration-white/30 underline-offset-4"

        {:errors, :errors} ->
          "text-amber-100 underline decoration-amber-200/40 underline-offset-4"

        _ ->
          "text-zinc-400"
      end

    [base, active]
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

  defp group_key(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id),
    do: {:cycle, cycle_id}

  defp group_key(%Entry{span_id: span_id}) when is_binary(span_id),
    do: {:span, span_id}

  defp group_key(%Entry{family: family}),
    do: {:family, family_group_key(family)}

  defp group_kind(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id),
    do: :cycle

  defp group_kind(%Entry{span_id: span_id}) when is_binary(span_id), do: :span
  defp group_kind(%Entry{family: family}), do: family_group_key(family)

  defp group_label(%Entry{cycle_id: cycle_id}) when is_binary(cycle_id),
    do: "cycle #{truncate_id(cycle_id, 12)}"

  defp group_label(%Entry{span_id: span_id}) when is_binary(span_id),
    do: "span #{truncate_id(span_id, 12)}"

  defp group_label(%Entry{family: family}),
    do: "#{family_label(family)} stream"

  defp group_label_class(:cycle),
    do: "text-[9px] uppercase tracking-[0.18em] text-sky-100"

  defp group_label_class(:span),
    do: "text-[9px] uppercase tracking-[0.18em] text-violet-100"

  defp group_label_class(:agent),
    do: "text-[9px] uppercase tracking-[0.18em] text-sky-100"

  defp group_label_class(:tool),
    do: "text-[9px] uppercase tracking-[0.18em] text-emerald-100"

  defp group_label_class(:llm),
    do: "text-[9px] uppercase tracking-[0.18em] text-fuchsia-100"

  defp group_label_class(:telegram),
    do: "text-[9px] uppercase tracking-[0.18em] text-sky-100"

  defp group_label_class(_),
    do: "text-[9px] uppercase tracking-[0.18em] text-zinc-300"

  defp scope_column_class(%Entry{family: "think"}),
    do: "whitespace-normal text-[11px] leading-5 text-cyan-200/70"

  defp scope_column_class(%Entry{}),
    do: "whitespace-normal text-[11px] leading-5 text-zinc-400"

  defp summary_class(%Entry{level: :error}),
    do: "text-[11px] font-semibold leading-4 text-rose-200"

  defp summary_class(%Entry{level: :warn}),
    do: "text-[11px] font-semibold leading-4 text-amber-100"

  defp summary_class(%Entry{family: "cycle"}),
    do: "text-[11px] font-semibold leading-4 text-sky-100"

  defp summary_class(%Entry{family: "think"}),
    do: "text-[11px] font-medium leading-4 text-cyan-100/75"

  defp summary_class(%Entry{family: "tool"}),
    do: "text-[11px] font-semibold leading-4 text-emerald-100"

  defp summary_class(%Entry{family: family}) when family in ["llm", "codex"],
    do: "text-[11px] font-semibold leading-4 text-fuchsia-100"

  defp summary_class(%Entry{family: "telegram"}),
    do: "text-[11px] font-semibold leading-4 text-sky-100"

  defp summary_class(%Entry{family: "task"}),
    do: "text-[11px] font-semibold leading-4 text-teal-100"

  defp summary_class(%Entry{}),
    do: "text-[11px] font-semibold leading-4 text-zinc-50"

  defp secondary_text_class(%Entry{family: "think"}),
    do:
      "whitespace-pre-wrap break-words font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[10px] leading-4 text-cyan-100/55"

  defp secondary_text_class(%Entry{level: :error}),
    do:
      "whitespace-pre-wrap break-words font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[10px] leading-4 text-rose-200/80"

  defp secondary_text_class(%Entry{}),
    do:
      "whitespace-pre-wrap break-words font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[10px] leading-4 text-zinc-400"

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

  defp family_column_palette(%Entry{level: :error}), do: "text-rose-200"
  defp family_column_palette(%Entry{level: :warn}), do: "text-amber-100"
  defp family_column_palette(%Entry{family: "cycle"}), do: "text-sky-100"
  defp family_column_palette(%Entry{family: "think"}), do: "text-cyan-100/75"
  defp family_column_palette(%Entry{family: "tool"}), do: "text-emerald-100"

  defp family_column_palette(%Entry{family: family})
       when family in ["llm", "codex"],
       do: "text-fuchsia-100"

  defp family_column_palette(%Entry{family: "telegram"}), do: "text-sky-100"
  defp family_column_palette(%Entry{family: "task"}), do: "text-teal-100"
  defp family_column_palette(%Entry{}), do: "text-zinc-300"

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
    do: "text-[10px] uppercase tracking-[0.18em] text-rose-100"

  defp exit_badge_class(_code),
    do: "text-[10px] uppercase tracking-[0.18em] text-zinc-300"

  defp family_group_key(family)
       when family in ["cycle", "think", "control", "message"],
       do: :agent

  defp family_group_key("tool"), do: :tool
  defp family_group_key("llm"), do: :llm
  defp family_group_key("codex"), do: :llm
  defp family_group_key("telegram"), do: :telegram
  defp family_group_key(_), do: :system
end
