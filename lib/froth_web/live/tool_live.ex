defmodule FrothWeb.ToolLive do
  use FrothWeb, :live_view

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.Cycle
  alias Froth.Agent.Event
  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.Inference.InferenceSession

  @elixir_keywords ~w(
    alias after case catch cond def defmodule defp do else end fn for if import in nil quote
    raise receive rescue require super try unquote unless use when with true false
  )

  @impl true
  def mount(params, _session, socket) do
    token = params["ref"] || params["tgWebAppStartParam"]

    # Route codex sessions to CodexLive through the same mini app entry point
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
      |> assign(:loop_mode, :legacy)
      |> assign(:inference_session_id, nil)
      |> assign(:cycle_id, nil)
      |> assign(:bot_id, "charlie")
      |> assign(:loop_topic, nil)
      |> assign(:raw_status, nil)
      |> assign(:loop_status, :loading)
      |> assign(:tool_steps, [])
      |> assign(:pending_tools, [])
      |> assign(:agent_events, [])
      |> assign(:next_pending_tool, nil)
      |> assign(:active_tool_ref, nil)
      |> assign(:subscribed_tool_refs, MapSet.new())
      |> assign(:live_thinking, "")
      |> assign(:live_text, "")
      |> assign(:live_io, "")
      |> assign(:live_result, nil)
      |> assign(:live_result_error, false)
      |> assign(:yolo, false)
      |> assign(:yolo_last_ref, nil)
      |> assign(:yolo_form, to_form(%{"yolo" => "false"}, as: :loop))

    {:ok, setup_loop(socket, token), layout: {FrothWeb.Layouts, :mini}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    token = params["tgWebAppStartParam"] || params["ref"]

    if token && socket.assigns.loop_key != token do
      socket = setup_loop(socket, token)

      socket =
        if socket.assigns.loop_mode == :legacy, do: maybe_yolo_approve(socket), else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("continue", _, socket) do
    if is_integer(socket.assigns.inference_session_id) do
      cast_bot(socket, {:continue_loop, socket.assigns.inference_session_id})
    end

    {:noreply, socket}
  end

  def handle_event("approve_tool", %{"ref" => ref}, socket) when is_binary(ref) do
    cast_bot(socket, {:auto_approve, ref})
    {:noreply, socket}
  end

  def handle_event("set_yolo", %{"loop" => params}, socket) when is_map(params) do
    yolo = checkbox_checked?(params["yolo"])

    socket =
      socket
      |> assign(:yolo, yolo)
      |> assign(:yolo_last_ref, if(yolo, do: socket.assigns.yolo_last_ref, else: nil))
      |> assign(:yolo_form, to_form(%{"yolo" => if(yolo, do: "true", else: "false")}, as: :loop))
      |> maybe_yolo_approve()

    {:noreply, socket}
  end

  def handle_event("stop", _, socket) do
    cond do
      socket.assigns.loop_mode == :agent_cycle and is_binary(socket.assigns.cycle_id) ->
        cast_bot(socket, {:stop_cycle, socket.assigns.cycle_id})

      is_integer(socket.assigns.inference_session_id) ->
        cast_bot(socket, {:stop_loop, socket.assigns.inference_session_id})

      true ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("refresh", _, socket) do
    {:noreply, refresh_loop(socket)}
  end

  def handle_event("close", _, socket) do
    {:noreply, push_event(socket, "tg-close", %{})}
  end

  @impl true
  def handle_info({:tool_loop, :updated}, socket) do
    {:noreply, refresh_loop(socket)}
  end

  def handle_info({:tool_step, step}, socket) when is_map(step) do
    steps = socket.assigns.tool_steps || []
    {:noreply, assign(socket, :tool_steps, steps ++ [step])}
  end

  def handle_info(
        {:event, _event, %AgentMessage{} = msg},
        %{assigns: %{loop_mode: :agent_cycle}} = socket
      ) do
    events = socket.assigns.agent_events ++ [agent_event_from_message(msg)]

    socket =
      if msg.role == :agent do
        socket |> assign(:live_thinking, "") |> assign(:live_text, "")
      else
        socket
      end

    {:noreply, assign(socket, :agent_events, events)}
  end

  def handle_info({:stream, {:thinking_start, _}}, socket) do
    {:noreply, assign(socket, :live_thinking, "")}
  end

  def handle_info({:stream, {:thinking_delta, %{"delta" => delta}}}, socket)
      when is_binary(delta) do
    {:noreply, assign(socket, :live_thinking, socket.assigns.live_thinking <> delta)}
  end

  def handle_info({:stream, {:text_delta, delta}}, socket) when is_binary(delta) do
    {:noreply, assign(socket, :live_text, socket.assigns.live_text <> delta)}
  end

  def handle_info({:stream, _}, socket), do: {:noreply, socket}

  def handle_info({:stream_event, {:thinking_start, _}}, socket) do
    {:noreply, assign(socket, :live_thinking, "")}
  end

  def handle_info({:stream_event, {:thinking_delta, %{"delta" => delta}}}, socket)
      when is_binary(delta) do
    {:noreply, assign(socket, :live_thinking, socket.assigns.live_thinking <> delta)}
  end

  def handle_info({:stream_event, {:text_delta, delta}}, socket) when is_binary(delta) do
    {:noreply, assign(socket, :live_text, socket.assigns.live_text <> delta)}
  end

  def handle_info({:io_chunk, text}, socket) when is_binary(text) do
    {:noreply, assign(socket, :live_io, socket.assigns.live_io <> text)}
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
     |> assign(:live_result_error, status == :error)}
  end

  def handle_info({:tool_aborted, _ref}, socket) do
    {:noreply,
     socket
     |> assign(:live_result, "Aborted by user.")
     |> assign(:live_result_error, true)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <%= if @loop_mode == :agent_cycle do %>
        <div
          id="agent-cycle-viewer"
          phx-hook="ToolScroll"
          data-follow-mode="always"
          class="min-h-screen bg-black text-zinc-100 text-[14px] font-mono flex flex-col"
        >
          <div id="agent-cycle-feed" class="flex-1 px-3 py-3">
            <div :for={item <- @agent_events} class="py-2 border-b border-zinc-900/70">
              <div class={[
                "text-[10px] uppercase tracking-wide mb-1",
                if(item.role == :agent, do: "text-emerald-300/80", else: "text-zinc-500")
              ]}>
                {if(item.role == :agent, do: "assistant", else: "user")}
              </div>
              <pre class="whitespace-pre-wrap leading-relaxed text-zinc-100">{item.text}</pre>
            </div>

            <div :if={@live_thinking != ""} class="py-2 border-b border-zinc-900/70">
              <div class="text-[10px] uppercase tracking-wide mb-1 text-zinc-500">thinking</div>
              <pre class="whitespace-pre-wrap leading-relaxed text-zinc-400/85 italic">{@live_thinking}</pre>
            </div>

            <div :if={@live_text != ""} class="py-2 border-b border-zinc-900/70">
              <div class="text-[10px] uppercase tracking-wide mb-1 text-emerald-300/80">
                assistant (streaming)
              </div>
              <pre class="whitespace-pre-wrap leading-relaxed text-zinc-100">{@live_text}</pre>
            </div>

            <div :if={@live_io != ""} class="py-2 border-b border-zinc-900/70">
              <div class="text-[10px] uppercase tracking-wide mb-1 text-zinc-500">io output</div>
              <pre class="whitespace-pre-wrap leading-relaxed text-zinc-300/90">{@live_io}</pre>
            </div>

            <div :if={is_binary(@live_result)} class="py-2">
              <div class={[
                "text-[10px] uppercase tracking-wide mb-1",
                if(@live_result_error, do: "text-red-300/80", else: "text-zinc-500")
              ]}>
                result
              </div>
              <.result_value result={@live_result || ""} is_error={@live_result_error} />
            </div>
          </div>

          <div class="border-t border-zinc-800/80 bg-black/98">
            <div class="px-3 py-2 flex flex-wrap items-center gap-2">
              <span class="text-[11px] text-zinc-300 truncate">
                cycle {@cycle_id}
              </span>
              <button
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
                id="loop-close"
                phx-click="close"
                class="min-h-9 px-2 text-[11px] text-zinc-500 hover:text-zinc-200 transition-colors"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      <% else %>
        <div
          id="tool-loop-viewer"
          phx-hook="ToolScroll"
          data-follow-mode={follow_mode(@yolo, @loop_status, @pending_tools)}
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
                  <% item.kind == :sent_message -> %>
                    <div class="ml-auto max-w-[94%] whitespace-pre-wrap leading-relaxed text-right text-emerald-200/95">
                      {item.body}
                    </div>
                  <% item.kind == :delivery_status -> %>
                    <div class={[
                      "text-[12px] pl-1",
                      if(item.is_error, do: "text-red-300/80", else: "text-zinc-400/70")
                    ]}>
                      {item.result}
                    </div>
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
              tool loop not found
            </div>
            <div :if={@loop_status == :loading} class="py-8 text-center text-zinc-500">...</div>
            <div id="tool-feed-end"></div>
          </div>

          <div
            id="loop-now-dock"
            class={[
              "border-t border-zinc-800/80",
              if(@yolo,
                do:
                  "bg-gradient-to-r from-black via-zinc-950 to-black shadow-[0_-6px_24px_rgba(16,185,129,0.16)]",
                else: "bg-black/98"
              )
            ]}
          >
            <% runnable_ref = next_runnable_ref(@pending_tools) %>
            <% runnable_name = next_runnable_name(@pending_tools) %>
            <div class="px-3 py-2 flex flex-wrap items-center gap-2">
              <div class="flex items-center gap-2 min-w-0 grow">
                <span
                  :if={show_dock_spinner?(@loop_status, @yolo, @pending_tools)}
                  class="inline-block size-2.5 rounded-full border border-zinc-500 border-t-zinc-100 animate-spin"
                >
                </span>
                <span
                  :if={@yolo}
                  class="text-[10px] tracking-[0.2em] uppercase text-emerald-300/90 animate-pulse"
                >
                  yolo
                </span>
                <span class="text-[11px] text-zinc-300 truncate">
                  {dock_text(@loop_status, @next_pending_tool, @pending_tools, @yolo)}
                </span>
              </div>

              <.form
                for={@yolo_form}
                id="loop-yolo-form"
                phx-change="set_yolo"
                class="[&_div.fieldset]:mb-0 [&_span.label]:inline-flex [&_span.label]:items-center [&_span.label]:gap-1.5 [&_span.label]:text-[11px] [&_span.label]:text-zinc-300 [&_label]:cursor-pointer"
              >
                <.input
                  field={@yolo_form[:yolo]}
                  type="checkbox"
                  label="YOLO"
                  class="size-3.5 rounded-sm border-zinc-500 bg-transparent"
                />
              </.form>

              <button
                :if={is_binary(runnable_ref)}
                phx-click="approve_tool"
                phx-value-ref={runnable_ref}
                title={if is_binary(runnable_name), do: tool_label(runnable_name), else: "Run"}
                class="min-h-9 px-3 text-[12px] text-zinc-100 border border-zinc-600 rounded-sm hover:border-zinc-400 transition-colors"
              >
                Run
              </button>
              <button
                :if={can_stop?(@raw_status)}
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
      <% end %>
    </Layouts.app>
    """
  end

  defp timeline_items(assigns) do
    step_timeline_items(assigns)
    |> maybe_append_live_thinking(assigns.live_thinking)
    |> maybe_append_live_text(assigns.live_text)
  end

  defp step_timeline_items(assigns) do
    steps = assigns.tool_steps || []

    state =
      steps
      |> Enum.with_index()
      |> Enum.reduce(
        %{entries: [], entry_keys: MapSet.new(), cards: %{}, tool_order: []},
        fn {step, idx}, acc -> apply_step_to_timeline(step, idx, acc) end
      )

    pending_tools = assigns.pending_tools || []

    state =
      pending_tools
      |> Enum.reduce(state, fn tool, acc ->
        key = tool_identity(tool)

        if key == :none do
          acc
        else
          acc
          |> upsert_timeline_card(key, %{
            ref: tool["ref"],
            tool_use_id: tool["tool_use_id"],
            name: tool["name"] || "tool",
            code: get_in(tool, ["input", "code"]),
            preview: safe_input_preview(tool["input"]),
            status: tool["status"] || "pending"
          })
          |> ensure_tool_entry(key)
        end
      end)

    pending_by_key =
      pending_tools
      |> Enum.with_index(1)
      |> Map.new(fn {tool, idx} -> {tool_identity(tool), {tool, idx}} end)

    queue_total = length(pending_tools)

    cards =
      Enum.reduce(state.tool_order, state.cards, fn key, acc ->
        card = Map.get(acc, key, %{})
        {tool, idx} = Map.get(pending_by_key, key, {%{}, nil})
        parsed = split_tool_result(tool["result"] || card.result || "")
        status = tool["status"] || card.status || "pending"
        ref = tool["ref"] || card.ref
        name = tool["name"] || card.name
        code = get_in(tool, ["input", "code"]) || card.code
        preview = card.preview || safe_input_preview(tool["input"])

        io_output =
          if status == "executing" and name == "elixir_eval" and assigns.live_io != "" do
            assigns.live_io
          else
            parsed.io_output || card.io_output || ""
          end

        result =
          cond do
            status == "executing" and name == "elixir_eval" and is_binary(assigns.live_result) ->
              assigns.live_result

            parsed.result != "" ->
              parsed.result

            true ->
              card.result || ""
          end

        is_error =
          cond do
            status == "executing" and name == "elixir_eval" and is_binary(assigns.live_result) ->
              assigns.live_result_error

            true ->
              tool["is_error"] == true or card.is_error == true
          end

        Map.put(acc, key, %{
          id: card.id || "q-step-#{key}",
          kind: :queue_tool,
          ref: ref,
          tool_use_id: card.tool_use_id || tool["tool_use_id"],
          name: name || "tool",
          status: status,
          code: code,
          preview: preview,
          queue_idx: idx || card.queue_idx,
          queue_total: if(idx, do: queue_total, else: card.queue_total),
          active: false,
          future: false,
          io_output: io_output || "",
          result: result || "",
          is_error: is_error
        })
      end)

    active_key =
      Enum.find(state.tool_order, fn key ->
        match?(%{status: "executing"}, Map.get(cards, key))
      end) ||
        Enum.find(state.tool_order, fn key ->
          match?(%{status: "pending"}, Map.get(cards, key))
        end)

    cards =
      Enum.reduce(state.tool_order, cards, fn key, acc ->
        case Map.get(acc, key) do
          %{status: status} = card ->
            active = key == active_key
            future = status == "pending" and not active
            Map.put(acc, key, %{card | active: active, future: future})

          _ ->
            acc
        end
      end)

    missing_tool_entries =
      state.tool_order
      |> Enum.reject(&MapSet.member?(state.entry_keys, &1))
      |> Enum.map(&{:tool, &1})

    entries = state.entries ++ missing_tool_entries

    Enum.reduce(entries, [], fn
      {:tool, key}, acc ->
        case Map.get(cards, key) do
          %{kind: :queue_tool} = card -> acc ++ [card]
          _ -> acc
        end

      item, acc ->
        acc ++ [item]
    end)
  end

  defp apply_step_to_timeline(%{"kind" => kind, "data" => data}, idx, state)
       when is_binary(kind) and is_map(data) do
    case kind do
      "assistant_thinking" ->
        case normalize_message_text(data["text"]) do
          nil ->
            state

          text ->
            append_timeline_entry(state, %{id: "step-think-#{idx}", kind: :thinking, body: text})
        end

      "assistant_text" ->
        case normalize_message_text(data["text"]) do
          nil ->
            state

          text ->
            append_timeline_entry(state, %{
              id: "step-text-#{idx}",
              kind: :assistant_text,
              body: text
            })
        end

      "tool_immediate" ->
        case immediate_message_text(data) do
          nil ->
            state

          text ->
            append_timeline_entry(state, %{id: "step-msg-#{idx}", kind: :sent_message, body: text})
        end

      "tool_queued" ->
        key = step_key(data)

        state
        |> upsert_timeline_card(key, %{
          ref: data["ref"],
          tool_use_id: data["tool_use_id"],
          name: data["name"] || "tool",
          status: "pending",
          code: data["code"],
          preview: data["input_preview"]
        })
        |> ensure_tool_entry(key)

      "tool_started" ->
        key = step_key(data)

        state
        |> upsert_timeline_card(key, %{
          ref: data["ref"],
          tool_use_id: data["tool_use_id"],
          name: data["name"] || "tool",
          status: "executing"
        })
        |> ensure_tool_entry(key)

      "tool_skipped" ->
        key = step_key(data)

        state
        |> upsert_timeline_card(key, %{
          ref: data["ref"],
          tool_use_id: data["tool_use_id"],
          name: data["name"] || "tool",
          status: "resolved",
          result: "User skipped this tool call.",
          is_error: false
        })
        |> ensure_tool_entry(key)

      "tool_aborted" ->
        key = step_key(data)

        state
        |> upsert_timeline_card(key, %{
          ref: data["ref"],
          tool_use_id: data["tool_use_id"],
          name: data["name"] || "tool",
          status: "resolved",
          result: "Aborted by user.",
          is_error: true
        })
        |> ensure_tool_entry(key)

      "tool_crashed" ->
        key = step_key(data)

        state
        |> upsert_timeline_card(key, %{
          ref: data["ref"],
          tool_use_id: data["tool_use_id"],
          name: data["name"] || "tool",
          status: "resolved",
          result: data["reason"] || "Tool crashed.",
          is_error: true
        })
        |> ensure_tool_entry(key)

      "tool_resolved" ->
        key = step_key(data)

        state
        |> upsert_timeline_card(key, %{
          ref: data["ref"],
          tool_use_id: data["tool_use_id"],
          name: data["name"] || "tool",
          status: "resolved",
          result: data["result"] || data["result_preview"] || "",
          is_error: data["is_error"] == true
        })
        |> ensure_tool_entry(key)

      "stream_error" ->
        append_step_error(state, idx, data["error"])

      "stream_crashed" ->
        append_step_error(state, idx, data["reason"])

      _ ->
        state
    end
  end

  defp apply_step_to_timeline(_step, _idx, state), do: state

  defp append_step_error(state, idx, value) do
    text =
      case value do
        v when is_binary(v) -> String.trim(v)
        _ -> nil
      end

    if is_binary(text) and text != "" do
      append_timeline_entry(state, %{
        id: "step-error-#{idx}",
        kind: :delivery_status,
        result: text,
        is_error: true
      })
    else
      state
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

  defp immediate_message_text(%{"name" => "send_message"} = data) do
    normalize_message_text(data["text"]) ||
      with preview when is_binary(preview) <- data["input_preview"],
           {:ok, %{"text" => text}} <- Jason.decode(preview) do
        normalize_message_text(text)
      else
        _ -> nil
      end
  end

  defp immediate_message_text(_), do: nil

  defp step_key(data) do
    data["tool_use_id"] || data["ref"] || "unknown"
  end

  defp ensure_order(order, key) do
    if key in order, do: order, else: order ++ [key]
  end

  defp tool_identity(tool) when is_map(tool) do
    tool["tool_use_id"] || tool["ref"] || :none
  end

  defp tool_identity(_), do: :none

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

  defp checkbox_checked?(value) when value in [true, "true", "on", "1", 1], do: true
  defp checkbox_checked?(_), do: false

  defp maybe_yolo_approve(%{assigns: %{yolo: false}} = socket) do
    assign(socket, :yolo_last_ref, nil)
  end

  defp maybe_yolo_approve(socket) do
    pending_tools = socket.assigns.pending_tools || []
    has_executing = Enum.any?(pending_tools, &(&1["status"] == "executing"))

    cond do
      socket.assigns.raw_status != "awaiting_tools" ->
        socket

      has_executing ->
        socket

      true ->
        case Enum.find(pending_tools, &(&1["status"] == "pending")) do
          %{"ref" => ref} when is_binary(ref) ->
            if socket.assigns.yolo_last_ref == ref do
              socket
            else
              cast_bot(socket, {:auto_approve, ref})
              assign(socket, :yolo_last_ref, ref)
            end

          _ ->
            assign(socket, :yolo_last_ref, nil)
        end
    end
  end

  defp setup_loop(socket, token) when is_binary(token) and token != "" do
    socket = assign(socket, :loop_key, token)

    case parse_agent_cycle_token(token) do
      {:ok, bot_id, cycle_id} ->
        setup_agent_cycle(socket, bot_id, cycle_id)

      :error ->
        case lookup_inference_session(token) do
          nil ->
            socket
            |> assign(:loop_mode, :legacy)
            |> assign(:cycle_id, nil)
            |> assign(:agent_events, [])
            |> assign(:inference_session_id, nil)
            |> assign(:bot_id, "charlie")
            |> assign(:loop_topic, nil)
            |> assign(:raw_status, nil)
            |> assign(:loop_status, :not_found)
            |> assign(:tool_steps, [])
            |> assign(:pending_tools, [])
            |> assign(:next_pending_tool, nil)
            |> assign(:active_tool_ref, nil)

          inference_session ->
            socket
            |> assign(:loop_mode, :legacy)
            |> assign(:cycle_id, nil)
            |> assign(:agent_events, [])
            |> maybe_subscribe_loop(inference_session.id)
            |> assign_from_inference_session(inference_session)
            |> maybe_subscribe_active_tool()
        end
    end
  end

  defp setup_loop(socket, _token), do: socket

  defp refresh_loop(%{assigns: %{loop_key: nil}} = socket), do: socket

  defp refresh_loop(socket) do
    socket =
      if socket.assigns.loop_mode == :agent_cycle and is_binary(socket.assigns.cycle_id) do
        events = load_agent_cycle_events(socket.assigns.cycle_id)
        assign(socket, :agent_events, events)
      else
        setup_loop(socket, socket.assigns.loop_key)
      end

    if socket.assigns.loop_mode == :legacy, do: maybe_yolo_approve(socket), else: socket
  end

  defp maybe_subscribe_loop(socket, inference_session_id) when is_integer(inference_session_id) do
    topic = "tool_loop:#{inference_session_id}"

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

  defp maybe_subscribe_loop(socket, _), do: socket

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

  defp maybe_subscribe_active_tool(socket) do
    ref = socket.assigns.active_tool_ref

    cond do
      not connected?(socket) ->
        socket

      not is_binary(ref) ->
        socket

      MapSet.member?(socket.assigns.subscribed_tool_refs, ref) ->
        socket

      true ->
        topic = "tool:#{ref}"
        Phoenix.PubSub.subscribe(Froth.PubSub, topic)

        assign(
          socket,
          :subscribed_tool_refs,
          MapSet.put(socket.assigns.subscribed_tool_refs, ref)
        )
    end
  end

  defp assign_from_inference_session(socket, inference_session) do
    pending_tools = inference_session.pending_tools || []
    next_pending_tool = Enum.find(pending_tools, &(&1["status"] == "pending"))

    active_eval_tool =
      Enum.find(pending_tools, &(&1["name"] == "elixir_eval" and &1["status"] == "executing"))

    socket =
      socket
      |> assign(:inference_session_id, inference_session.id)
      |> assign(:bot_id, inference_session.bot_id || "charlie")
      |> assign(:raw_status, inference_session.status)
      |> assign(
        :loop_status,
        loop_status(inference_session.status, next_pending_tool, active_eval_tool)
      )
      |> assign(:tool_steps, inference_session.tool_steps || [])
      |> assign(:pending_tools, pending_tools)
      |> assign(:next_pending_tool, next_pending_tool)
      |> assign(:active_tool_ref, active_eval_tool && active_eval_tool["ref"])

    socket =
      if inference_session.status == "streaming" do
        socket
      else
        socket |> assign(:live_thinking, "") |> assign(:live_text, "")
      end

    if active_eval_tool do
      socket
    else
      socket
      |> assign(:live_io, "")
      |> assign(:live_result, nil)
      |> assign(:live_result_error, false)
    end
  end

  defp setup_agent_cycle(socket, bot_id, cycle_id)
       when is_binary(bot_id) and is_binary(cycle_id) do
    case Froth.Repo.get(Cycle, cycle_id) do
      nil ->
        socket
        |> assign(:loop_mode, :agent_cycle)
        |> assign(:cycle_id, cycle_id)
        |> assign(:bot_id, bot_id)
        |> assign(:loop_status, :not_found)
        |> assign(:agent_events, [])
        |> assign(:inference_session_id, nil)

      _cycle ->
        events = load_agent_cycle_events(cycle_id)

        socket
        |> assign(:loop_mode, :agent_cycle)
        |> assign(:cycle_id, cycle_id)
        |> assign(:bot_id, bot_id)
        |> assign(:loop_status, :running)
        |> assign(:agent_events, events)
        |> assign(:inference_session_id, nil)
        |> assign(:pending_tools, [])
        |> assign(:tool_steps, [])
        |> assign(:next_pending_tool, nil)
        |> assign(:active_tool_ref, nil)
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

  defp lookup_inference_session(token) do
    case parse_loop_token(token) do
      {:inference_session_id, inference_session_id} ->
        Froth.Repo.get(InferenceSession, inference_session_id)

      {:tool_ref, ref} ->
        Froth.Repo.one(
          from(c in InferenceSession,
            where:
              fragment(
                "EXISTS (SELECT 1 FROM jsonb_array_elements(?) elem WHERE elem->>'ref' = ?)",
                c.pending_tools,
                ^ref
              ),
            order_by: [desc: c.id],
            limit: 1
          ),
          log: false
        )

      :invalid ->
        nil
    end
  end

  defp parse_loop_token(token) when is_binary(token) do
    cond do
      String.starts_with?(token, "session_") ->
        case Integer.parse(String.replace_prefix(token, "session_", "")) do
          {id, ""} -> {:inference_session_id, id}
          _ -> :invalid
        end

      true ->
        {:tool_ref, token}
    end
  end

  defp parse_loop_token(_), do: :invalid

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
      text: agent_event_text(content)
    }
  end

  defp agent_event_from_message(_), do: %{id: Ecto.ULID.generate(), role: :user, text: ""}

  defp agent_event_text(%{"_wrapped" => value}) when is_binary(value), do: value

  defp agent_event_text(%{"_wrapped" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "thinking", "thinking" => text} when is_binary(text) -> text
      %{"type" => "tool_result", "content" => content} when is_binary(content) -> content
      other -> inspect(other, limit: 20, printable_limit: 500)
    end)
    |> Enum.join("\n")
  end

  defp agent_event_text(content) when is_binary(content), do: content
  defp agent_event_text(content), do: inspect(content, limit: 20, printable_limit: 500)

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

  defp can_stop?(status) when status in ["awaiting_tools", "streaming"], do: true
  defp can_stop?(_), do: false

  defp next_runnable_ref(pending_tools) when is_list(pending_tools) do
    if Enum.any?(pending_tools, &(&1["status"] == "executing")) do
      nil
    else
      case Enum.find(pending_tools, &(&1["status"] == "pending")) do
        %{"ref" => ref} when is_binary(ref) -> ref
        _ -> nil
      end
    end
  end

  defp next_runnable_ref(_), do: nil

  defp next_runnable_name(pending_tools) when is_list(pending_tools) do
    if Enum.any?(pending_tools, &(&1["status"] == "executing")) do
      nil
    else
      case Enum.find(pending_tools, &(&1["status"] == "pending")) do
        %{"name" => name} when is_binary(name) -> name
        _ -> nil
      end
    end
  end

  defp next_runnable_name(_), do: nil

  defp show_dock_spinner?(loop_status, yolo, pending_tools) do
    loop_status in [:running, :thinking] or
      (yolo and is_list(pending_tools) and Enum.any?(pending_tools, &(&1["status"] == "pending")))
  end

  defp follow_mode(yolo, loop_status, pending_tools) do
    if yolo and show_dock_spinner?(loop_status, true, pending_tools), do: "always", else: "smart"
  end

  defp dock_text(_loop_status, _next_pending_tool, pending_tools, true)
       when is_list(pending_tools) do
    cond do
      Enum.any?(pending_tools, &(&1["status"] == "executing")) ->
        "running..."

      match?(%{"name" => _}, Enum.find(pending_tools, &(&1["status"] == "pending"))) ->
        "yolo armed"

      true ->
        "yolo armed"
    end
  end

  defp dock_text(:thinking, _next_pending_tool, _pending_tools, _yolo), do: "thinking..."
  defp dock_text(:running, _next_pending_tool, _pending_tools, _yolo), do: "running..."
  defp dock_text(:done, _next_pending_tool, _pending_tools, _yolo), do: "loop complete"
  defp dock_text(:stopped, _next_pending_tool, _pending_tools, _yolo), do: "stopped"
  defp dock_text(:error, _next_pending_tool, _pending_tools, _yolo), do: "loop failed"
  defp dock_text(:not_found, _next_pending_tool, _pending_tools, _yolo), do: "loop not found"

  defp dock_text(:paused, pending_tool, _pending_tools, _yolo) when is_map(pending_tool) do
    "ready: #{tool_label(pending_tool["name"])}"
  end

  defp dock_text(_, _next_pending_tool, _pending_tools, _yolo), do: "waiting"

  defp loop_status("awaiting_tools", pending_tool, active_eval_tool) do
    cond do
      is_map(active_eval_tool) -> :running
      is_map(pending_tool) -> :paused
      true -> :loading
    end
  end

  defp loop_status("streaming", _pending_tool, _active_eval_tool), do: :thinking
  defp loop_status("done", _pending_tool, _active_eval_tool), do: :done
  defp loop_status("stopped", _pending_tool, _active_eval_tool), do: :stopped
  defp loop_status("error", _pending_tool, _active_eval_tool), do: :error
  defp loop_status(_, _pending_tool, _active_eval_tool), do: :loading

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

  defp token_class({:kw_identifier, _pos, ident}) when is_atom(ident), do: "text-fuchsia-300"
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

  # Interpolated string parts can include tokenizer metadata tuples; skip highlighting those strings.
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
