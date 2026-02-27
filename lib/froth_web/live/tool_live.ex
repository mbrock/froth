defmodule FrothWeb.ToolLive do
  use FrothWeb, :live_view

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.Cycle
  alias Froth.Agent.Event
  alias Froth.Agent.Message, as: AgentMessage

  @elixir_keywords ~w(
    alias after case catch cond def defmodule defp do else end fn for if import in nil quote
    raise receive rescue require super try unquote unless use when with true false
  )

  @impl true
  def mount(params, _session, socket) do
    token = params["ref"] || params["tgWebAppStartParam"]

    if is_binary(token) and String.starts_with?(token, "codex_") do
      {:ok, push_navigate(socket, to: "/froth/mini/codex/#{token}"),
       layout: {FrothWeb.Layouts, :mini}}
    else
      mount_tool(token, socket)
    end
  end

  defp mount_tool(token, socket) do
    socket =
      socket
      |> assign(:loop_key, nil)
      |> assign(:cycle_id, nil)
      |> assign(:bot_id, "charlie")
      |> assign(:loop_topic, nil)
      |> assign(:loop_status, :loading)
      |> assign(:agent_events, [])
      |> assign(:live_thinking, "")
      |> assign(:live_text, "")
      |> assign(:live_io, "")
      |> assign(:live_result, nil)
      |> assign(:live_result_error, false)

    {:ok, setup_loop(socket, token), layout: {FrothWeb.Layouts, :mini}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    token = params["tgWebAppStartParam"] || params["ref"]

    if token && socket.assigns.loop_key != token do
      {:noreply, setup_loop(socket, token)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop", _, socket) do
    if is_binary(socket.assigns.cycle_id) do
      cast_bot(socket, {:stop_cycle, socket.assigns.cycle_id})
    end

    {:noreply,
     socket
     |> assign(:loop_status, :stopped)
     |> assign(:live_thinking, "")
     |> assign(:live_text, "")}
  end

  def handle_event("refresh", _, socket) do
    {:noreply, refresh_loop(socket)}
  end

  def handle_event("close", _, socket) do
    {:noreply, push_event(socket, "tg-close", %{})}
  end

  @impl true
  def handle_info({:event, _event, %AgentMessage{} = msg}, socket) do
    events = socket.assigns.agent_events ++ [agent_event_from_message(msg)]

    socket =
      if msg.role == :agent do
        socket
        |> assign(:live_thinking, "")
        |> assign(:live_text, "")
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:agent_events, events)
     |> assign(
       :loop_status,
       derive_cycle_status(events, socket.assigns.live_thinking, socket.assigns.live_text)
     )}
  end

  def handle_info({:stream, {:thinking_start, _}}, socket) do
    {:noreply, socket |> assign(:live_thinking, "") |> assign(:loop_status, :thinking)}
  end

  def handle_info({:stream, {:thinking_delta, %{"delta" => delta}}}, socket)
      when is_binary(delta) do
    {:noreply,
     socket
     |> assign(:live_thinking, socket.assigns.live_thinking <> delta)
     |> assign(:loop_status, :thinking)}
  end

  def handle_info({:stream, {:text_delta, delta}}, socket) when is_binary(delta) do
    {:noreply,
     socket
     |> assign(:live_text, socket.assigns.live_text <> delta)
     |> assign(:loop_status, :thinking)}
  end

  def handle_info({:stream, _}, socket), do: {:noreply, socket}

  def handle_info({:stream_event, {:thinking_start, _}}, socket) do
    {:noreply, socket |> assign(:live_thinking, "") |> assign(:loop_status, :thinking)}
  end

  def handle_info({:stream_event, {:thinking_delta, %{"delta" => delta}}}, socket)
      when is_binary(delta) do
    {:noreply,
     socket
     |> assign(:live_thinking, socket.assigns.live_thinking <> delta)
     |> assign(:loop_status, :thinking)}
  end

  def handle_info({:stream_event, {:text_delta, delta}}, socket) when is_binary(delta) do
    {:noreply,
     socket
     |> assign(:live_text, socket.assigns.live_text <> delta)
     |> assign(:loop_status, :thinking)}
  end

  def handle_info({:io_chunk, text}, socket) when is_binary(text) do
    {:noreply,
     socket |> assign(:live_io, socket.assigns.live_io <> text) |> assign(:loop_status, :running)}
  end

  def handle_info(
        {:eval_done_detail, %{status: status, io_output: io_output, result: result}},
        socket
      )
      when status in [:ok, :error] and is_binary(result) do
    {:noreply,
     socket
     |> assign(:live_io, io_output || "")
     |> assign(:live_result, result)
     |> assign(:live_result_error, status == :error)
     |> assign(:loop_status, :running)}
  end

  def handle_info({:tool_aborted, _ref}, socket) do
    {:noreply,
     socket
     |> assign(:live_result, "Aborted by user.")
     |> assign(:live_result_error, true)
     |> assign(:loop_status, :running)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div
        id="tool-loop-viewer"
        phx-hook="ToolScroll"
        data-follow-mode={follow_mode(@loop_status)}
        class="min-h-screen bg-black text-zinc-100 text-[14px] font-mono flex flex-col"
      >
        <div id="tool-feed" class="flex-1 px-3 py-3">
          <%= for {item, idx} <- Enum.with_index(timeline_items(assigns)) do %>
            <div class={[idx > 0 && "mt-3 pt-3 border-t border-zinc-900/80"]}>
              <%= cond do %>
                <% item.kind == :thinking -> %>
                  <div class="pl-1 whitespace-pre-wrap text-[13px] leading-relaxed text-zinc-400/80 italic">
                    {item.body}
                  </div>
                <% item.kind == :assistant_text -> %>
                  <div class="max-w-[94%] whitespace-pre-wrap leading-relaxed text-zinc-100">
                    {item.body}
                  </div>
                <% item.kind == :user_text -> %>
                  <div class="max-w-[94%] whitespace-pre-wrap leading-relaxed text-zinc-500/90">
                    {item.body}
                  </div>
                <% item.kind == :sent_message -> %>
                  <div class="ml-auto max-w-[94%] whitespace-pre-wrap leading-relaxed text-right text-emerald-200/95">
                    {item.body}
                  </div>
                <% item.kind == :delivery_status -> %>
                  <pre class={[
                    "whitespace-pre-wrap text-[12px] pl-1 leading-snug",
                    if(item.is_error, do: "text-red-300/80", else: "text-zinc-400/70")
                  ]}>{item.result}</pre>
                <% item.kind == :queue_tool -> %>
                  <div class={[
                    "pl-3 space-y-2 border-l transition-opacity",
                    item.active && "border-zinc-500/80",
                    item.future && "border-zinc-700/40 opacity-45",
                    !item.active && !item.future && "border-zinc-700/60"
                  ]}>
                    <div class="flex items-center justify-between gap-2">
                      <span class="text-[12px] text-zinc-300/90">
                        {queue_action_title(item.name)}
                      </span>
                      <span class={[
                        "text-[10px] uppercase tracking-wide",
                        tool_status_color(item.status, item.is_error)
                      ]}>
                        {queue_status_text(item.status)}
                      </span>
                    </div>

                    <pre
                      :if={item.code}
                      class="whitespace-pre-wrap text-[12px] font-mono leading-snug text-zinc-100"
                    ><%= highlight_elixir(item.code) %></pre>
                    <pre
                      :if={is_nil(item.code) and is_binary(item.preview) and item.preview != ""}
                      class="whitespace-pre-wrap text-[12px] font-mono leading-snug text-zinc-300/90"
                    >{item.preview}</pre>

                    <%= if item.io_output != "" or item.result != "" do %>
                      <pre
                        :if={item.io_output != ""}
                        class="whitespace-pre-wrap text-[12px] font-mono leading-snug text-zinc-400/85"
                      >{item.io_output}</pre>
                      <.result_value result={item.result || ""} is_error={item.is_error} />
                    <% end %>
                  </div>
              <% end %>
            </div>
          <% end %>

          <div :if={@loop_status == :not_found} class="py-8 text-center text-zinc-500">
            cycle not found
          </div>
          <div :if={@loop_status == :loading} class="py-8 text-center text-zinc-500">...</div>
          <div id="tool-feed-end"></div>
        </div>

        <div id="loop-now-dock" class="border-t border-zinc-800/80 bg-black/98">
          <div class="px-3 py-2 flex flex-wrap items-center gap-2">
            <div class="flex items-center gap-2 min-w-0 grow">
              <span
                :if={show_dock_spinner?(@loop_status)}
                class="inline-block size-2.5 rounded-full border border-zinc-500 border-t-zinc-100 animate-spin"
              >
              </span>
              <span class="text-[11px] text-zinc-300 truncate">
                {dock_text(@loop_status, @cycle_id)}
              </span>
            </div>

            <button
              :if={can_stop?(@loop_status)}
              id="loop-stop"
              phx-click="stop"
              class="min-h-9 px-3 text-[12px] text-red-200/90 border border-red-500/35 rounded-sm hover:bg-red-500/10 transition-colors"
            >
              Stop
            </button>
            <button
              id="loop-refresh"
              phx-click="refresh"
              class="min-h-9 px-2 text-[11px] text-zinc-500 hover:text-zinc-200 transition-colors"
            >
              Refresh
            </button>
            <button
              :if={@loop_status in [:done, :stopped, :error, :not_found]}
              id="loop-close"
              phx-click="close"
              class="min-h-9 px-2 text-[11px] text-zinc-500 hover:text-zinc-200 transition-colors"
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp timeline_items(assigns) do
    cycle_timeline_items(assigns)
    |> maybe_append_live_thinking(assigns.live_thinking)
    |> maybe_append_live_text(assigns.live_text)
  end

  defp cycle_timeline_items(assigns) do
    state =
      (assigns.agent_events || [])
      |> Enum.reduce(
        %{
          entries: [],
          entry_keys: MapSet.new(),
          cards: %{},
          tool_order: [],
          immediate_tool_ids: MapSet.new()
        },
        &apply_agent_event_to_timeline/2
      )
      |> finalize_tool_cards(assigns)

    missing_tool_entries =
      state.tool_order
      |> Enum.reject(&MapSet.member?(state.entry_keys, &1))
      |> Enum.map(&{:tool, &1})

    entries = state.entries ++ missing_tool_entries

    Enum.reduce(entries, [], fn
      {:tool, key}, acc ->
        case Map.get(state.cards, key) do
          %{kind: :queue_tool} = card -> acc ++ [card]
          _ -> acc
        end

      item, acc ->
        acc ++ [item]
    end)
  end

  defp apply_agent_event_to_timeline(%{id: event_id, role: role, blocks: blocks}, state)
       when role in [:agent, :user] and is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(state, fn {block, idx}, acc ->
      apply_agent_block(role, event_id, block, idx, acc)
    end)
  end

  defp apply_agent_event_to_timeline(_, state), do: state

  defp apply_agent_block(role, event_id, %{"type" => "thinking", "thinking" => text}, idx, state)
       when role == :agent do
    append_timeline_text(state, :thinking, text, event_id, idx)
  end

  defp apply_agent_block(role, event_id, %{"type" => "text", "text" => text}, idx, state)
       when role == :agent do
    append_timeline_text(state, :assistant_text, text, event_id, idx)
  end

  defp apply_agent_block(role, event_id, %{"type" => "text", "text" => text}, idx, state)
       when role == :user do
    append_timeline_text(state, :user_text, text, event_id, idx)
  end

  defp apply_agent_block(role, event_id, %{"type" => "tool_use"} = block, idx, state)
       when role == :agent do
    apply_tool_use(state, event_id, idx, block)
  end

  defp apply_agent_block(_role, event_id, %{"type" => "tool_result"} = block, idx, state) do
    apply_tool_result(state, event_id, idx, block)
  end

  defp apply_agent_block(_role, _event_id, _block, _idx, state), do: state

  defp apply_tool_use(state, event_id, idx, block) when is_map(block) do
    tool_use_id = block["id"] || "#{event_id}-tool-#{idx}"
    name = block["name"] || "tool"

    if name == "send_message" do
      state =
        case normalize_message_text(get_in(block, ["input", "text"])) do
          nil ->
            state

          text ->
            append_timeline_entry(state, %{
              id: "#{event_id}-sent-#{idx}",
              kind: :sent_message,
              body: text
            })
        end

      %{state | immediate_tool_ids: MapSet.put(state.immediate_tool_ids, tool_use_id)}
    else
      state
      |> upsert_timeline_card(tool_use_id, %{
        ref: tool_use_id,
        tool_use_id: tool_use_id,
        name: name,
        status: "executing",
        code: get_in(block, ["input", "code"]),
        preview: safe_input_preview(block["input"])
      })
      |> ensure_tool_entry(tool_use_id)
    end
  end

  defp apply_tool_result(state, event_id, idx, block) when is_map(block) do
    key = block["tool_use_id"] || "#{event_id}-tool-result-#{idx}"
    parsed = split_tool_result(block["content"])
    is_error = block["is_error"] == true

    if MapSet.member?(state.immediate_tool_ids, key) do
      result_text =
        cond do
          is_binary(parsed.result) and String.trim(parsed.result) != "" -> parsed.result
          is_binary(parsed.io_output) and String.trim(parsed.io_output) != "" -> parsed.io_output
          true -> nil
        end

      if is_error or
           (is_binary(result_text) and String.downcase(String.trim(result_text)) != "sent") do
        append_timeline_entry(state, %{
          id: "#{event_id}-delivery-#{idx}",
          kind: :delivery_status,
          result: result_text || "tool result",
          is_error: is_error
        })
      else
        state
      end
    else
      state
      |> upsert_timeline_card(key, %{
        ref: key,
        tool_use_id: key,
        status: "resolved",
        result: parsed.result || "",
        io_output: parsed.io_output || "",
        is_error: is_error
      })
      |> ensure_tool_entry(key)
    end
  end

  defp finalize_tool_cards(state, assigns) do
    active_key =
      Enum.find(state.tool_order, fn key ->
        match?(%{status: "executing"}, Map.get(state.cards, key))
      end)

    cards =
      Enum.reduce(state.tool_order, state.cards, fn key, acc ->
        card = Map.get(acc, key, %{})
        active = key == active_key

        io_output =
          if active and card.name == "elixir_eval" and assigns.live_io != "" do
            assigns.live_io
          else
            card.io_output || ""
          end

        result =
          cond do
            active and card.name == "elixir_eval" and is_binary(assigns.live_result) ->
              assigns.live_result

            true ->
              card.result || ""
          end

        is_error =
          cond do
            active and card.name == "elixir_eval" and is_binary(assigns.live_result) ->
              assigns.live_result_error

            true ->
              card.is_error == true
          end

        Map.put(acc, key, %{
          card
          | active: active,
            future: false,
            io_output: io_output,
            result: result,
            is_error: is_error
        })
      end)

    %{state | cards: cards}
  end

  defp append_timeline_text(state, kind, text, event_id, idx) do
    case normalize_message_text(text) do
      nil ->
        state

      body ->
        append_timeline_entry(state, %{id: "#{event_id}-#{kind}-#{idx}", kind: kind, body: body})
    end
  end

  defp append_timeline_entry(state, item) when is_map(item) do
    %{state | entries: state.entries ++ [item]}
  end

  defp upsert_timeline_card(state, key, attrs) do
    base = %{
      id: "q-step-#{key}",
      kind: :queue_tool,
      ref: nil,
      tool_use_id: nil,
      name: "tool",
      status: "pending",
      code: nil,
      preview: nil,
      queue_idx: nil,
      queue_total: nil,
      active: false,
      future: false,
      io_output: "",
      result: "",
      is_error: false
    }

    card =
      state.cards
      |> Map.get(key, base)
      |> Map.merge(attrs)

    %{
      state
      | cards: Map.put(state.cards, key, card),
        tool_order: ensure_order(state.tool_order, key)
    }
  end

  defp ensure_tool_entry(state, key) do
    if MapSet.member?(state.entry_keys, key) do
      state
    else
      %{
        state
        | entries: state.entries ++ [{:tool, key}],
          entry_keys: MapSet.put(state.entry_keys, key),
          tool_order: ensure_order(state.tool_order, key)
      }
    end
  end

  defp ensure_order(order, key) do
    if key in order, do: order, else: order ++ [key]
  end

  defp safe_input_preview(nil), do: nil

  defp safe_input_preview(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> String.slice(json, 0, 1000)
      _ -> inspect(input, limit: 100, printable_limit: 1000)
    end
  end

  defp safe_input_preview(_), do: nil

  defp maybe_append_live_thinking(feed, ""), do: feed

  defp maybe_append_live_thinking(feed, text) do
    feed ++ [%{id: "live-thinking", kind: :thinking, body: text}]
  end

  defp maybe_append_live_text(feed, ""), do: feed

  defp maybe_append_live_text(feed, text) do
    feed ++ [%{id: "live-text", kind: :assistant_text, body: text}]
  end

  defp normalize_message_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.split("\n", trim: false)
    |> strip_common_indent()
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_message_text(_), do: nil

  defp strip_common_indent(lines) when is_list(lines) do
    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&leading_indent_size/1)
      |> Enum.min(fn -> 0 end)

    if min_indent <= 0 do
      lines
    else
      Enum.map(lines, fn line ->
        if String.trim(line) == "" do
          ""
        else
          String.slice(line, min_indent..-1//1) || ""
        end
      end)
    end
  end

  defp leading_indent_size(line) when is_binary(line) do
    case Regex.run(~r/^[ \t]*/, line) do
      [indent] -> String.length(indent)
      _ -> 0
    end
  end

  defp setup_loop(socket, token) when is_binary(token) and token != "" do
    socket = assign(socket, :loop_key, token)

    case parse_agent_cycle_token(token) do
      {:ok, bot_id, cycle_id} ->
        setup_agent_cycle(socket, bot_id, cycle_id)

      :error ->
        clear_cycle(socket, :not_found)
    end
  end

  defp setup_loop(socket, _token), do: clear_cycle(socket, :not_found)

  defp refresh_loop(%{assigns: %{cycle_id: cycle_id}} = socket) when is_binary(cycle_id) do
    case Froth.Repo.get(Cycle, cycle_id) do
      nil ->
        clear_cycle(socket, :not_found)

      _cycle ->
        events = load_agent_cycle_events(cycle_id)

        socket
        |> assign(:agent_events, events)
        |> assign(
          :loop_status,
          derive_cycle_status(events, socket.assigns.live_thinking, socket.assigns.live_text)
        )
    end
  end

  defp refresh_loop(socket), do: socket

  defp clear_cycle(socket, status) do
    socket = maybe_unsubscribe_loop_topic(socket)

    socket
    |> assign(:cycle_id, nil)
    |> assign(:bot_id, "charlie")
    |> assign(:loop_status, status)
    |> assign(:agent_events, [])
    |> assign(:live_thinking, "")
    |> assign(:live_text, "")
    |> assign(:live_io, "")
    |> assign(:live_result, nil)
    |> assign(:live_result_error, false)
  end

  defp maybe_subscribe_cycle(socket, cycle_id) when is_binary(cycle_id) do
    topic = "cycle:#{cycle_id}"

    socket =
      if connected?(socket) do
        if socket.assigns.loop_topic && socket.assigns.loop_topic != topic do
          Phoenix.PubSub.unsubscribe(Froth.PubSub, socket.assigns.loop_topic)
        end

        if socket.assigns.loop_topic != topic do
          Phoenix.PubSub.subscribe(Froth.PubSub, topic)
        end

        socket
      else
        socket
      end

    assign(socket, :loop_topic, topic)
  end

  defp maybe_subscribe_cycle(socket, _), do: socket

  defp maybe_unsubscribe_loop_topic(socket) do
    if connected?(socket) and is_binary(socket.assigns.loop_topic) do
      Phoenix.PubSub.unsubscribe(Froth.PubSub, socket.assigns.loop_topic)
    end

    assign(socket, :loop_topic, nil)
  end

  defp setup_agent_cycle(socket, bot_id, cycle_id)
       when is_binary(bot_id) and is_binary(cycle_id) do
    case Froth.Repo.get(Cycle, cycle_id) do
      nil ->
        socket
        |> clear_cycle(:not_found)
        |> assign(:bot_id, bot_id)

      _cycle ->
        events = load_agent_cycle_events(cycle_id)

        socket
        |> assign(:cycle_id, cycle_id)
        |> assign(:bot_id, bot_id)
        |> assign(:agent_events, events)
        |> assign(:live_thinking, "")
        |> assign(:live_text, "")
        |> assign(:live_io, "")
        |> assign(:live_result, nil)
        |> assign(:live_result_error, false)
        |> assign(:loop_status, derive_cycle_status(events))
        |> maybe_subscribe_cycle(cycle_id)
    end
  end

  defp load_agent_cycle_events(cycle_id) when is_binary(cycle_id) do
    head_id =
      Froth.Repo.one(
        from(e in Event,
          where: e.cycle_id == ^cycle_id,
          order_by: [desc: e.seq],
          limit: 1,
          select: e.head_id
        ),
        log: false
      )

    head_id
    |> Agent.load_messages()
    |> Enum.map(&agent_event_from_message/1)
  end

  defp load_agent_cycle_events(_), do: []

  defp parse_agent_cycle_token(token) when is_binary(token) do
    case Regex.run(~r/^cycle_([^_]+)_(.+)$/, token, capture: :all_but_first) do
      [bot_id, cycle_id] -> {:ok, bot_id, cycle_id}
      _ -> :error
    end
  end

  defp parse_agent_cycle_token(_), do: :error

  defp cast_bot(socket, message) do
    Froth.Telegram.Bots.cast(socket.assigns.bot_id || "charlie", message)
  end

  defp agent_event_from_message(%AgentMessage{id: id, role: role, content: content}) do
    %{
      id: id || Ecto.ULID.generate(),
      role: role,
      blocks: agent_event_blocks(content)
    }
  end

  defp agent_event_from_message(_), do: %{id: Ecto.ULID.generate(), role: :user, blocks: []}

  defp agent_event_blocks(%{"_wrapped" => value}) when is_binary(value) do
    [%{"type" => "text", "text" => value}]
  end

  defp agent_event_blocks(%{"_wrapped" => blocks}) when is_list(blocks), do: blocks

  defp agent_event_blocks(content) when is_binary(content) do
    [%{"type" => "text", "text" => content}]
  end

  defp agent_event_blocks(_), do: []

  defp derive_cycle_status(events), do: derive_cycle_status(events, "", "")

  defp derive_cycle_status(events, live_thinking, live_text) do
    cond do
      live_thinking != "" or live_text != "" ->
        :thinking

      unresolved_tool_calls(events) > 0 ->
        :running

      events == [] ->
        :running

      true ->
        :done
    end
  end

  defp unresolved_tool_calls(events) when is_list(events) do
    pending =
      Enum.reduce(events, MapSet.new(), fn event, acc ->
        blocks = event[:blocks] || []

        Enum.reduce(blocks, acc, fn
          %{"type" => "tool_use", "id" => id, "name" => name}, pending
          when is_binary(id) and is_binary(name) ->
            if name == "send_message", do: pending, else: MapSet.put(pending, id)

          %{"type" => "tool_use", "id" => id}, pending when is_binary(id) ->
            MapSet.put(pending, id)

          %{"type" => "tool_result", "tool_use_id" => id}, pending when is_binary(id) ->
            MapSet.delete(pending, id)

          _, pending ->
            pending
        end)
      end)

    MapSet.size(pending)
  end

  defp unresolved_tool_calls(_), do: 0

  defp split_tool_result(content) when is_binary(content) do
    if String.starts_with?(content, "IO output:\n") do
      rest = String.replace_prefix(content, "IO output:\n", "")

      case String.split(rest, "\n\n", parts: 2) do
        [io_output, result] -> %{io_output: io_output, result: result}
        [single] -> %{io_output: single, result: ""}
      end
    else
      %{io_output: "", result: content}
    end
  end

  defp split_tool_result(content) when is_list(content) do
    result =
      content
      |> Enum.map(&tool_result_block_summary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    %{io_output: "", result: result}
  end

  defp split_tool_result(nil), do: %{io_output: "", result: ""}
  defp split_tool_result(content), do: %{io_output: "", result: inspect(content, limit: 30)}

  defp tool_result_block_summary(%{"type" => "text", "text" => text}) when is_binary(text),
    do: text

  defp tool_result_block_summary(%{"type" => "image", "source" => source}) when is_map(source),
    do: "[image #{source["media_type"] || "unknown"}]"

  defp tool_result_block_summary(%{"type" => "document", "source" => source})
       when is_map(source),
       do: "[document #{source["media_type"] || "unknown"}]"

  defp tool_result_block_summary(%{"type" => type}) when is_binary(type), do: "[#{type}]"
  defp tool_result_block_summary(_), do: ""

  attr(:result, :string, required: true)
  attr(:is_error, :boolean, default: false)

  defp result_value(assigns) do
    doc_text = as_doc_string(assigns.result)
    assigns = assign(assigns, :doc_text, doc_text)

    ~H"""
    <%= if @doc_text do %>
      <div class="space-y-3 text-[13px] leading-relaxed text-zinc-200/90">
        <p :for={paragraph <- doc_paragraphs(@doc_text)} class="whitespace-pre-wrap">
          {paragraph}
        </p>
      </div>
    <% else %>
      <pre class={[
        "whitespace-pre-wrap text-[12px] font-mono leading-snug",
        if(@is_error, do: "text-red-300/85", else: "text-zinc-200/90")
      ]}>{@result}</pre>
    <% end %>
    """
  end

  defp as_doc_string(result) when is_binary(result) do
    with {:ok, ast} <- Code.string_to_quoted(result),
         true <- is_binary(ast),
         true <- doc_string?(ast) do
      ast
    else
      _ -> nil
    end
  end

  defp as_doc_string(_), do: nil

  defp doc_string?(text) when is_binary(text) do
    line_count = text |> String.split("\n", trim: false) |> length()
    line_count >= 3
  end

  defp doc_paragraphs(text) when is_binary(text) do
    text
    |> String.split(~r/\n\s*\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp can_stop?(status) when status in [:running, :thinking], do: true
  defp can_stop?(_), do: false

  defp show_dock_spinner?(loop_status), do: loop_status in [:running, :thinking, :loading]

  defp follow_mode(loop_status),
    do: if(loop_status in [:running, :thinking], do: "always", else: "smart")

  defp dock_text(:loading, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} loading..."
  defp dock_text(:running, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} running..."

  defp dock_text(:thinking, cycle_id) when is_binary(cycle_id),
    do: "cycle #{cycle_id} thinking..."

  defp dock_text(:done, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} complete"
  defp dock_text(:stopped, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} stopped"
  defp dock_text(:error, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} failed"
  defp dock_text(:not_found, _cycle_id), do: "cycle not found"
  defp dock_text(_, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id}"
  defp dock_text(_, _), do: "waiting"

  defp tool_status_color("executing", _), do: "text-yellow-300/80"
  defp tool_status_color("pending", _), do: "text-amber-300/80"
  defp tool_status_color("resolved", true), do: "text-red-300/80"
  defp tool_status_color("resolved", _), do: "text-green-300/80"
  defp tool_status_color("stopped", _), do: "text-orange-300/80"
  defp tool_status_color(_, _), do: "text-white/40"

  defp tool_label("read_log"), do: "Read log"
  defp tool_label("search"), do: "Search history"
  defp tool_label("view_analysis"), do: "Read analysis"
  defp tool_label("look"), do: "Look at media"
  defp tool_label("send_message"), do: "Send message"
  defp tool_label("elixir_eval"), do: "Run code (Elixir)"
  defp tool_label(name) when is_binary(name), do: name
  defp tool_label(_), do: "tool"

  defp queue_action_title("elixir_eval"), do: "Code"
  defp queue_action_title(name) when is_binary(name), do: tool_label(name)
  defp queue_action_title(_), do: "Action"

  defp queue_status_text("pending"), do: "ready"
  defp queue_status_text("executing"), do: "running"
  defp queue_status_text("resolved"), do: "done"
  defp queue_status_text("stopped"), do: "stopped"
  defp queue_status_text(status) when is_binary(status), do: status
  defp queue_status_text(_), do: ""

  defp highlight_elixir(code) when is_binary(code) do
    chars = String.to_charlist(code)
    offsets = line_offsets(code)

    ranges =
      case :elixir_tokenizer.tokenize(chars, 1, []) do
        {:ok, _line, _column, _warnings, tokens, _terminators} ->
          tokens
          |> Enum.reverse()
          |> Enum.flat_map(&token_range(&1, offsets, chars))

        _ ->
          []
      end

    Phoenix.HTML.raw(render_highlighted(chars, ranges))
  end

  defp highlight_elixir(_), do: ""

  defp line_offsets(code) do
    code
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, 0}, fn {line, line_no}, {acc, offset} ->
      len = line |> String.to_charlist() |> length()
      {Map.put(acc, line_no, offset), offset + len + 1}
    end)
    |> elem(0)
  end

  defp token_range(token, offsets, chars) do
    with {line, col} <- token_position(token),
         class when is_binary(class) <- token_class(token),
         start when is_integer(start) <- position_to_index(offsets, line, col),
         len when is_integer(len) and len > 0 <- token_length(token),
         true <- start + len <= length(chars) do
      [%{start: start, len: len, class: class}]
    else
      _ -> []
    end
  end

  defp token_position({_type, {line, col, _meta}}) when is_integer(line) and is_integer(col),
    do: {line, col}

  defp token_position({_type, {line, col, _meta}, _value})
       when is_integer(line) and is_integer(col),
       do: {line, col}

  defp token_position(_), do: nil

  defp position_to_index(offsets, line, col) when is_integer(line) and is_integer(col) do
    case Map.fetch(offsets, line) do
      {:ok, offset} -> offset + col - 1
      :error -> nil
    end
  end

  defp token_class({type, _}) when type in [:alias], do: "text-sky-300"
  defp token_class({type, _, _}) when type in [:alias], do: "text-sky-300"
  defp token_class({type, _, _}) when type in [:atom], do: "text-cyan-300"
  defp token_class({type, _, _}) when type in [:int, :float], do: "text-amber-300"
  defp token_class({:at_op, _, _}), do: "text-fuchsia-300"
  defp token_class({:bin_string, _, _}), do: "text-emerald-300"

  defp token_class({:identifier, _pos, ident}) when ident in [true, false, nil],
    do: "text-fuchsia-300"

  defp token_class({:identifier, _pos, ident}) when is_atom(ident) do
    if Atom.to_string(ident) in @elixir_keywords, do: "text-fuchsia-300", else: nil
  end

  defp token_class({:kw_identifier, _pos, _ident}), do: "text-fuchsia-300"
  defp token_class({type, _pos}) when type in [:do, :end], do: "text-fuchsia-300"
  defp token_class(_), do: nil

  defp token_length({:identifier, {_, _, text}, _}) when is_list(text), do: length(text)
  defp token_length({:paren_identifier, {_, _, text}, _}) when is_list(text), do: length(text)
  defp token_length({:kw_identifier, {_, _, text}, _}) when is_list(text), do: length(text)
  defp token_length({:alias, {_, _, text}, _}) when is_list(text), do: length(text)
  defp token_length({:atom, {_, _, text}, _}) when is_list(text), do: length(text) + 1
  defp token_length({:int, _meta, text}) when is_list(text), do: length(text)
  defp token_length({:float, _meta, text}) when is_list(text), do: length(text)
  defp token_length({:at_op, _meta, _}), do: 1

  defp token_length({:bin_string, _meta, parts}) when is_list(parts) do
    case bin_string_parts_len(parts) do
      {:ok, content_len} -> content_len + 2
      :error -> nil
    end
  end

  defp token_length({type, {_line, _col, _meta}}) when is_atom(type) do
    Atom.to_string(type) |> String.to_charlist() |> length()
  end

  defp token_length(_), do: nil

  defp bin_string_parts_len(parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, 0}, fn part, {:ok, acc} ->
      case bin_string_part_len(part) do
        {:ok, len} -> {:cont, {:ok, acc + len}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp bin_string_part_len(part) when is_binary(part) do
    {:ok, part |> String.to_charlist() |> length()}
  end

  defp bin_string_part_len(part) when is_list(part) do
    if List.ascii_printable?(part) do
      {:ok, length(part)}
    else
      :error
    end
  end

  defp bin_string_part_len(_), do: :error

  defp render_highlighted(chars, ranges) do
    ranges = Enum.sort_by(ranges, & &1.start)
    total = length(chars)

    {pieces, cursor} =
      Enum.reduce(ranges, {[], 0}, fn %{start: start, len: len, class: class}, {acc, pos} ->
        if start < pos or start >= total do
          {acc, pos}
        else
          plain = slice_escaped(chars, pos, start - pos)
          token_text = slice_escaped(chars, start, len)
          span = "<span class=\"#{class}\">#{token_text}</span>"
          {[acc, plain, span], start + len}
        end
      end)

    tail = slice_escaped(chars, cursor, total - cursor)
    IO.iodata_to_binary([pieces, tail])
  end

  defp slice_escaped(_chars, _start, len) when len <= 0, do: ""

  defp slice_escaped(chars, start, len) do
    chars
    |> Enum.slice(start, len)
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
