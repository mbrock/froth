defmodule FrothWeb.ToolLive do
  use FrothWeb, :live_view

  alias Froth.Agent
  alias Froth.Agent.{Cycle, ToolDescription}
  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.Repo
  alias Froth.Telegram.CycleLink

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
      |> assign(:follow_tail?, true)
      |> assign(:chat_id, nil)
      |> assign(:reply_to, nil)
      |> assign(:steer_form, to_form(%{"prompt" => ""}, as: :steer))

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
     |> assign(:loop_status, :stopping)
     |> assign(:live_thinking, "")
     |> assign(:live_text, "")}
  end

  def handle_event("refresh", _, socket) do
    {:noreply, refresh_loop(socket)}
  end

  def handle_event("toggle_follow_tail", _, socket) do
    {:noreply, assign(socket, :follow_tail?, !socket.assigns.follow_tail?)}
  end

  def handle_event("send_steer", %{"steer" => %{"prompt" => raw_prompt}}, socket) do
    prompt = String.trim(raw_prompt || "")

    socket =
      cond do
        prompt == "" ->
          socket

        show_steer_input?(
          socket.assigns.loop_status,
          socket.assigns.chat_id,
          socket.assigns.cycle_id
        ) ->
          cast_bot(socket, {:start_inference_session, steer_message(socket, prompt)})

          socket
          |> assign(:agent_events, socket.assigns.agent_events ++ [local_steer_event(prompt)])
          |> assign(:loop_status, :running)

        true ->
          put_flash(socket, :error, "Steering is unavailable for this run.")
      end

    {:noreply, assign(socket, :steer_form, to_form(%{"prompt" => ""}, as: :steer))}
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
        data-follow-mode={follow_mode(@follow_tail?)}
        class="mini-shell safe-top flex min-h-0 flex-col bg-[radial-gradient(circle_at_top,rgba(24,24,34,0.72),rgba(5,5,8,1)_46%)] text-zinc-100"
      >
        <header class="sticky top-0 z-30 border-b border-zinc-800/70 bg-zinc-950/92 backdrop-blur">
          <div class="mx-auto w-full max-w-3xl px-2 py-1.5">
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-1.5 font-mono text-[10px]">
                  <span class={loop_status_badge_class(@loop_status)}>
                    {loop_status_badge_text(@loop_status)}
                  </span>
                  <span :if={is_binary(@cycle_id)} class="text-zinc-500">
                    {short_cycle_id(@cycle_id)}
                  </span>
                  <span :if={tool_progress_label(@agent_events)} class="text-zinc-500">
                    {tool_progress_label(@agent_events)}
                  </span>
                  <span
                    :if={loop_working?(@loop_status)}
                    class="inline-flex items-center gap-1 text-sky-200/90"
                  >
                    <span>live</span>
                    <.working_dots />
                  </span>
                </div>
                <p class="mt-0.5 truncate text-[11px] text-zinc-400">
                  {dock_text(@loop_status, @cycle_id)}
                </p>
              </div>

              <label class="mini-toggle shrink-0" data-active={to_string(@follow_tail?)}>
                <input
                  id="tool-follow-tail"
                  type="checkbox"
                  checked={@follow_tail?}
                  phx-click="toggle_follow_tail"
                />
                <span>Latest</span>
              </label>
            </div>
          </div>
        </header>

        <main
          id="tool-feed"
          data-scroll-body
          class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-1.5 py-1.5"
        >
          <div class="mx-auto w-full max-w-3xl space-y-1.5">
            <%= for {item, idx} <- Enum.with_index(timeline_items(assigns)) do %>
              <div id={"tool-item-#{idx}"}>
                <%= cond do %>
                  <% item.kind == :thinking -> %>
                    <div class="rounded-xl border border-zinc-800/70 bg-zinc-950/45 px-2.5 py-1.5 text-[11px] italic leading-5 text-zinc-400/80">
                      {item.body}
                    </div>
                  <% item.kind == :assistant_text -> %>
                    <.transcript_text body={item.body} tone={:assistant} />
                  <% item.kind == :user_text -> %>
                    <.transcript_text body={item.body} tone={:user} />
                  <% item.kind == :sent_message -> %>
                    <.transcript_text body={item.body} tone={:sent} />
                  <% item.kind == :delivery_status -> %>
                    <div class={[
                      "max-w-[96%] rounded-xl border px-2.5 py-1.5 text-[11px] leading-5",
                      if(item.is_error,
                        do: "border-rose-500/35 bg-rose-950/35 text-rose-100",
                        else: "border-zinc-800/80 bg-zinc-950/60 text-zinc-300"
                      )
                    ]}>
                      {item.result}
                    </div>
                  <% item.kind == :queue_tool -> %>
                    <.tool_card item={item} />
                <% end %>
              </div>
            <% end %>

            <div :if={@loop_status == :not_found} class="py-8 text-center text-[12px] text-zinc-500">
              cycle not found
            </div>
            <div :if={@loop_status == :loading} class="py-8 text-center text-[12px] text-zinc-500">
              ...
            </div>
            <div id="tool-feed-end" data-scroll-end></div>
          </div>
        </main>

        <div
          id="loop-now-dock"
          class="safe-bottom border-t border-zinc-800/80 bg-zinc-950/95 backdrop-blur"
        >
          <div class="mx-auto w-full max-w-3xl px-2 py-2">
            <div class="flex flex-wrap items-center justify-end gap-1.5">
              <button
                :if={can_stop?(@loop_status, @cycle_id)}
                id="loop-stop"
                phx-click="stop"
                class="mini-btn mini-btn--danger"
              >
                Stop
              </button>
              <button id="loop-refresh" phx-click="refresh" class="mini-btn">
                Refresh
              </button>
              <button
                :if={@loop_status in [:done, :stopped, :stopping, :error, :not_found]}
                id="loop-close"
                phx-click="close"
                class="mini-btn"
              >
                Close
              </button>
            </div>

            <.form
              :if={show_steer_input?(@loop_status, @chat_id, @cycle_id)}
              for={@steer_form}
              id="loop-steer-form"
              phx-submit="send_steer"
              class="mt-1.5 flex items-end gap-2 pb-[calc(0.2rem+var(--kb,0px))]"
            >
              <.input
                field={@steer_form[:prompt]}
                type="textarea"
                rows="1"
                placeholder="Steer this run..."
                enterkeyhint="send"
                class="mini-input min-h-[2.75rem] resize-none"
              />
              <button id="loop-steer" type="submit" class="mini-btn mini-btn--accent min-h-[2.75rem]">
                Steer
              </button>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :body, :string, required: true
  attr :tone, :atom, required: true

  defp transcript_text(assigns) do
    {text, footer} = split_cost_footer(assigns.body)

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:footer, footer)
      |> assign(:html, render_markdown_html(text))

    ~H"""
    <%= if @text do %>
      <div class={transcript_card_class(@tone)}>
        <div class={transcript_text_class(@tone)}>{raw(@html)}</div>
        <div :if={@footer} class="mt-1.5">
          <.metadata_footer footer={@footer} />
        </div>
      </div>
    <% else %>
      <.metadata_footer :if={@footer} footer={@footer} />
    <% end %>
    """
  end

  attr :footer, :string, required: true

  defp metadata_footer(assigns) do
    ~H"""
    <div class="inline-flex rounded-full border border-zinc-700/80 bg-zinc-950/90 px-2 py-0.5 font-mono text-[10px] text-zinc-400">
      {@footer}
    </div>
    """
  end

  attr :class, :string, default: nil

  defp working_dots(assigns) do
    ~H"""
    <span class={["mini-dots", @class]}>
      <span></span>
      <span></span>
      <span></span>
    </span>
    """
  end

  attr :item, :map, required: true

  defp tool_card(assigns) do
    assigns =
      assigns
      |> assign(:card_class, tool_card_class(assigns.item))
      |> assign(:badge_class, tool_badge_class(assigns.item))
      |> assign(:badge_text, tool_badge_text(assigns.item))
      |> assign(:summary, tool_primary_summary(assigns.item))
      |> assign(:error_note, tool_error_note(assigns.item))

    ~H"""
    <div class={@card_class}>
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-1.5">
            <.icon name="hero-wrench-screwdriver" class="size-3.5 shrink-0 text-amber-300/85" />
            <p class="truncate text-[12px] font-semibold tracking-[0.02em] text-zinc-50">
              {queue_action_title(@item.name)}
            </p>
            <span class="shrink-0 rounded-full border border-zinc-700/80 bg-zinc-950/85 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.14em] text-zinc-500">
              {@item.name}
            </span>
          </div>

          <p
            :if={@item.narration}
            class="mt-1 font-sans text-[13px] italic leading-[1.45] text-zinc-200/90"
          >
            {@item.narration}
          </p>

          <div
            :if={@summary}
            class="mt-1 rounded-lg border border-zinc-800/80 bg-black/20 px-2 py-1 font-mono text-[11px] leading-5 text-zinc-300/85"
          >
            {@summary}
          </div>

          <p
            :if={@error_note}
            class="mt-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-rose-200/90"
          >
            {@error_note}
          </p>
        </div>

        <span class={@badge_class}>
          {@badge_text}
        </span>
      </div>

      <details
        :if={tool_has_input?(@item)}
        id={"tool-input-#{@item.tool_use_id || @item.ref || @item.id}"}
        class="mt-1.5 rounded-lg border border-zinc-800/80 bg-black/15"
        open
      >
        <summary class="cursor-pointer list-none px-2 py-1 text-[10px] font-medium uppercase tracking-[0.14em] text-zinc-400 [&::-webkit-details-marker]:hidden">
          Input
        </summary>
        <div class="border-t border-zinc-800/80 px-2 py-2">
          <pre class="max-h-64 overflow-auto whitespace-pre-wrap font-mono text-[11px] leading-5 text-zinc-300/90">{@item.input_json}</pre>
        </div>
      </details>

      <details
        :if={tool_has_output?(@item)}
        id={"tool-output-#{@item.tool_use_id || @item.ref || @item.id}"}
        class="mt-1.5 rounded-lg border border-zinc-800/80 bg-black/15"
        open
      >
        <summary class="cursor-pointer list-none px-2 py-1 text-[10px] font-medium uppercase tracking-[0.14em] text-zinc-400 [&::-webkit-details-marker]:hidden">
          Output
        </summary>
        <div class="space-y-2 border-t border-zinc-800/80 px-2 py-2">
          <div :if={@item.io_output != ""}>
            <p class="mb-1 font-mono text-[10px] uppercase tracking-[0.14em] text-zinc-500">IO</p>
            <pre class="max-h-56 overflow-auto whitespace-pre-wrap font-mono text-[11px] leading-5 text-zinc-400/90">{@item.io_output}</pre>
          </div>

          <div :if={@item.result != ""}>
            <p class="mb-1 font-mono text-[10px] uppercase tracking-[0.14em] text-zinc-500">
              Result
            </p>
            <.result_value result={@item.result || ""} is_error={tool_failure?(@item)} />
          </div>
        </div>
      </details>
    </div>
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

  defp apply_agent_block(role, event_id, %{"type" => type} = block, idx, state)
       when role == :agent and type in ["tool_use", "mcp_tool_use"] do
    apply_tool_use(state, event_id, idx, block)
  end

  defp apply_agent_block(_role, event_id, %{"type" => type} = block, idx, state)
       when type in ["tool_result", "mcp_tool_result"] do
    apply_tool_result(state, event_id, idx, block)
  end

  defp apply_agent_block(_role, _event_id, _block, _idx, state), do: state

  defp apply_tool_use(state, event_id, idx, block) when is_map(block) do
    tool_use_id = block["id"] || "#{event_id}-tool-#{idx}"
    name = format_tool_block_name(block)
    input = Map.get(block, "input")

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
        narration: ToolDescription.text_from_input(input),
        summary: tool_input_summary(name, input),
        input_json: pretty_tool_input(input)
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

  defp format_tool_block_name(%{"server_name" => server_name, "name" => name})
       when is_binary(server_name) and server_name != "" and is_binary(name) do
    "#{server_name}/#{name}"
  end

  defp format_tool_block_name(%{"name" => name}) when is_binary(name), do: name
  defp format_tool_block_name(_block), do: "tool"

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
      narration: nil,
      summary: nil,
      input_json: nil,
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
        cycle_link = load_cycle_link(cycle_id)

        socket
        |> assign(:agent_events, events)
        |> assign(:chat_id, cycle_link && cycle_link.chat_id)
        |> assign(:reply_to, cycle_link && cycle_link.reply_to)
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
    |> assign(:chat_id, nil)
    |> assign(:reply_to, nil)
    |> assign(:steer_form, to_form(%{"prompt" => ""}, as: :steer))
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
        cycle_link = load_cycle_link(cycle_id)
        resolved_bot_id = (cycle_link && cycle_link.bot_id) || bot_id

        socket
        |> assign(:cycle_id, cycle_id)
        |> assign(:bot_id, resolved_bot_id)
        |> assign(:agent_events, events)
        |> assign(:live_thinking, "")
        |> assign(:live_text, "")
        |> assign(:live_io, "")
        |> assign(:live_result, nil)
        |> assign(:live_result_error, false)
        |> assign(:chat_id, cycle_link && cycle_link.chat_id)
        |> assign(:reply_to, cycle_link && cycle_link.reply_to)
        |> assign(:steer_form, to_form(%{"prompt" => ""}, as: :steer))
        |> assign(:loop_status, derive_cycle_status(events))
        |> maybe_subscribe_cycle(cycle_id)
    end
  end

  defp load_agent_cycle_events(cycle_id) when is_binary(cycle_id) do
    head_id = Agent.latest_head_id(%Cycle{id: cycle_id})

    head_id
    |> Agent.load_messages()
    |> Enum.map(&agent_event_from_message/1)
  end

  defp load_agent_cycle_events(_), do: []

  defp load_cycle_link(cycle_id) when is_binary(cycle_id) do
    Repo.get_by(CycleLink, cycle_id: cycle_id)
  end

  defp load_cycle_link(_), do: nil

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

  defp agent_event_blocks(blocks) when is_list(blocks), do: blocks

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
          %{"type" => type, "id" => id, "name" => name}, pending
          when type in ["tool_use", "mcp_tool_use"] and is_binary(id) and is_binary(name) ->
            if name == "send_message", do: pending, else: MapSet.put(pending, id)

          %{"type" => type, "id" => id}, pending
          when type in ["tool_use", "mcp_tool_use"] and is_binary(id) ->
            MapSet.put(pending, id)

          %{"type" => type, "tool_use_id" => id}, pending
          when type in ["tool_result", "mcp_tool_result"] and is_binary(id) ->
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

  defp local_steer_event(prompt) when is_binary(prompt) do
    %{
      id: "steer-" <> Integer.to_string(System.unique_integer([:positive])),
      role: :user,
      blocks: [%{"type" => "text", "text" => prompt}]
    }
  end

  defp can_stop?(status, cycle_id)
       when is_binary(cycle_id) and status not in [:stopped, :stopping, :not_found],
       do: true

  defp can_stop?(_status, _cycle_id), do: false

  defp loop_working?(loop_status), do: loop_status in [:running, :thinking, :loading, :stopping]

  defp show_steer_input?(loop_status, chat_id, cycle_id),
    do:
      loop_status in [:running, :thinking, :stopping] and is_integer(chat_id) and
        is_binary(cycle_id)

  defp follow_mode(true), do: "always"
  defp follow_mode(false), do: "manual"
  defp follow_mode(_), do: "always"

  defp steer_message(socket, prompt) do
    %{
      "chat_id" => socket.assigns.chat_id,
      "id" => socket.assigns.reply_to || 0,
      "content" => %{"text" => %{"text" => prompt}}
    }
  end

  defp dock_text(:loading, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} loading..."
  defp dock_text(:running, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} running..."

  defp dock_text(:thinking, cycle_id) when is_binary(cycle_id),
    do: "cycle #{cycle_id} thinking..."

  defp dock_text(:stopping, cycle_id) when is_binary(cycle_id),
    do: "cycle #{cycle_id} stop requested..."

  defp dock_text(:done, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} complete"
  defp dock_text(:stopped, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} stopped"
  defp dock_text(:error, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id} failed"
  defp dock_text(:not_found, _cycle_id), do: "cycle not found"
  defp dock_text(_, cycle_id) when is_binary(cycle_id), do: "cycle #{cycle_id}"
  defp dock_text(_, _), do: "waiting"

  defp loop_status_badge_class(:running),
    do:
      "inline-flex items-center rounded-full border border-amber-500/35 bg-amber-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-amber-200"

  defp loop_status_badge_class(:thinking),
    do:
      "inline-flex items-center rounded-full border border-sky-500/35 bg-sky-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-sky-200"

  defp loop_status_badge_class(:done),
    do:
      "inline-flex items-center rounded-full border border-emerald-500/35 bg-emerald-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-emerald-200"

  defp loop_status_badge_class(:error),
    do:
      "inline-flex items-center rounded-full border border-rose-500/35 bg-rose-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-rose-200"

  defp loop_status_badge_class(:not_found),
    do:
      "inline-flex items-center rounded-full border border-zinc-700/80 bg-zinc-900/80 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-zinc-400"

  defp loop_status_badge_class(:stopping),
    do:
      "inline-flex items-center rounded-full border border-orange-500/35 bg-orange-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-orange-200"

  defp loop_status_badge_class(_),
    do:
      "inline-flex items-center rounded-full border border-zinc-700/80 bg-zinc-900/80 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-zinc-400"

  defp loop_status_badge_text(:thinking), do: "thinking"
  defp loop_status_badge_text(:running), do: "running"
  defp loop_status_badge_text(:done), do: "done"
  defp loop_status_badge_text(:error), do: "error"
  defp loop_status_badge_text(:loading), do: "loading"
  defp loop_status_badge_text(:not_found), do: "missing"
  defp loop_status_badge_text(:stopping), do: "stopping"
  defp loop_status_badge_text(:stopped), do: "stopped"
  defp loop_status_badge_text(_), do: "waiting"

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

  defp transcript_card_class(:assistant),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/70 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp transcript_card_class(:user),
    do:
      "ml-auto max-w-[96%] rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/50 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp transcript_card_class(:sent),
    do:
      "ml-auto max-w-[96%] rounded-[0.9rem] border border-emerald-500/30 bg-emerald-500/10 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp transcript_card_class(_),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/70 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp transcript_text_class(:assistant),
    do: "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-zinc-100"

  defp transcript_text_class(:user),
    do:
      "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-zinc-300/90 text-right [&_*]:text-right"

  defp transcript_text_class(:sent),
    do:
      "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-right text-emerald-50 [&_*]:text-right"

  defp transcript_text_class(_),
    do: "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-zinc-100"

  defp split_cost_footer(text) when is_binary(text) do
    trimmed = String.trim(text)

    case Regex.run(
           ~r/^(.*?)(?:\n{2,}|\n)?(\[[0-9]+(?:\.[0-9]+)?s \| [^\]\n]+ in \| [^\]\n]+ out \| \$[0-9]+(?:\.[0-9]+)?\])$/s,
           trimmed,
           capture: :all_but_first
         ) do
      [body, footer] ->
        {blank_to_nil(body), footer}

      _ ->
        {blank_to_nil(trimmed), nil}
    end
  end

  defp split_cost_footer(_), do: {nil, nil}

  defp render_markdown_html(text) when is_binary(text) do
    escaped_text =
      text
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    options = %Earmark.Options{
      breaks: true,
      code_class_prefix: "language-",
      escape: false,
      smartypants: false
    }

    case Earmark.as_html(escaped_text, options) do
      {:ok, html, _} -> html
      {:error, html, _} -> html
      _ -> escaped_text
    end
  end

  defp render_markdown_html(_), do: ""

  defp tool_progress_label(events) do
    {total, resolved} = tool_progress(events)

    cond do
      total <= 0 -> nil
      resolved >= total -> "#{total} tools"
      true -> "#{resolved}/#{total} tools"
    end
  end

  defp tool_progress(events) when is_list(events) do
    {calls, resolved} =
      Enum.reduce(events, {MapSet.new(), MapSet.new()}, fn event, {calls, resolved} ->
        blocks = event[:blocks] || []

        Enum.reduce(blocks, {calls, resolved}, fn
          %{"type" => type, "id" => id, "name" => name}, {call_acc, result_acc}
          when type in ["tool_use", "mcp_tool_use"] and is_binary(id) and is_binary(name) ->
            if name == "send_message",
              do: {call_acc, result_acc},
              else: {MapSet.put(call_acc, id), result_acc}

          %{"type" => type, "tool_use_id" => id}, {call_acc, result_acc}
          when type in ["tool_result", "mcp_tool_result"] and is_binary(id) ->
            {call_acc, MapSet.put(result_acc, id)}

          _, acc ->
            acc
        end)
      end)

    {MapSet.size(calls), MapSet.size(MapSet.intersection(calls, resolved))}
  end

  defp tool_progress(_), do: {0, 0}

  defp short_cycle_id(cycle_id) when is_binary(cycle_id), do: String.slice(cycle_id, 0, 12)
  defp short_cycle_id(_), do: nil

  defp tool_card_class(item) do
    cond do
      tool_failure?(item) ->
        "rounded-[0.9rem] border border-rose-500/35 bg-rose-950/30 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"

      item.status == "executing" ->
        "rounded-[0.9rem] border border-amber-500/30 bg-amber-950/20 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"

      true ->
        "rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/68 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"
    end
  end

  defp tool_badge_class(item) do
    cond do
      tool_failure?(item) ->
        "inline-flex items-center rounded-full border border-rose-500/35 bg-rose-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-rose-100"

      item.status == "executing" ->
        "inline-flex items-center rounded-full border border-amber-500/35 bg-amber-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-amber-100"

      true ->
        "inline-flex items-center rounded-full border border-emerald-500/35 bg-emerald-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.14em] text-emerald-100"
    end
  end

  defp tool_badge_text(item) do
    exit_code = tool_exit_code(item)

    cond do
      item.status == "executing" -> "running"
      is_integer(exit_code) and exit_code > 0 -> "exit #{exit_code}"
      tool_failure?(item) -> "error"
      true -> queue_status_text(item.status)
    end
  end

  defp tool_error_note(item) do
    case tool_exit_code(item) do
      139 -> "Likely segfault"
      code when is_integer(code) and code > 0 -> "Non-zero exit"
      _ when item.is_error == true -> "Tool returned an error"
      _ -> nil
    end
  end

  defp tool_primary_summary(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp tool_primary_summary(%{preview: preview}) when is_binary(preview) and preview != "",
    do: preview

  defp tool_primary_summary(_), do: nil

  defp tool_has_input?(%{input_json: text}) when is_binary(text) and text != "", do: true
  defp tool_has_input?(_), do: false

  defp tool_has_output?(%{io_output: io_output, result: result}) do
    (is_binary(io_output) and io_output != "") or (is_binary(result) and result != "")
  end

  defp tool_has_output?(_), do: false

  defp tool_failure?(item) when is_map(item) do
    item.is_error == true or
      item.status == "stopped" or
      match?(code when is_integer(code) and code > 0, tool_exit_code(item))
  end

  defp tool_failure?(_), do: false

  defp tool_exit_code(item) when is_map(item) do
    Enum.find_value([item.result, item.io_output], &extract_exit_code/1)
  end

  defp tool_exit_code(_), do: nil

  defp extract_exit_code(text) when is_binary(text) do
    # New structured form: <output kind="shell" exit_code="N" ...>
    # Legacy form: "exit code: N" / "exit N" / "(exit code: N)"
    patterns = [
      ~r/\bexit_code="(\d+)"/,
      ~r/\bexit(?:\s+code)?[:\s\)]*(\d+)\b/i
    ]

    Enum.find_value(patterns, fn re ->
      case Regex.run(re, text, capture: :all_but_first) do
        [value] -> String.to_integer(value)
        _ -> nil
      end
    end)
  end

  defp extract_exit_code(_), do: nil

  defp tool_input_summary("run_shell", input) when is_map(input) do
    input["command"]
    |> normalize_message_text()
    |> summarize_preview()
  end

  defp tool_input_summary("elixir_eval", input) when is_map(input) do
    input["code"]
    |> normalize_message_text()
    |> summarize_preview()
  end

  defp tool_input_summary(_name, input) when is_map(input) do
    input
    |> Map.drop(["description", "narration"])
    |> safe_input_preview()
    |> summarize_preview()
  end

  defp tool_input_summary(_name, _input), do: nil

  defp pretty_tool_input(input) when is_map(input) or is_list(input) do
    case Jason.encode(input, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(input, pretty: true, limit: 100, printable_limit: 5000)
    end
  end

  defp pretty_tool_input(input) when is_binary(input), do: input
  defp pretty_tool_input(nil), do: nil

  defp pretty_tool_input(input),
    do: inspect(input, pretty: true, limit: 100, printable_limit: 5000)

  defp summarize_preview(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        lines = trimmed |> String.split("\n", trim: false) |> Enum.take(3)
        preview = Enum.join(lines, "\n")
        if String.length(trimmed) > String.length(preview), do: preview <> "\n...", else: preview
    end
  end

  defp summarize_preview(_), do: nil

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
