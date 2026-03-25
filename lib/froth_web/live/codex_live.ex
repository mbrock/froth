defmodule FrothWeb.CodexLive do
  use FrothWeb, :live_view

  alias Froth.Codex.Events, as: CodexEvents
  alias Froth.Telemetry.Span
  alias Froth.Codex.Session, as: CodexSession

  @entry_kinds %{
    "assistant" => :assistant,
    "error" => :error,
    "event" => :event,
    "reasoning" => :reasoning,
    "status" => :status,
    "system" => :system,
    "tool" => :tool,
    "user" => :user
  }

  @impl true
  def mount(params, _session, socket) do
    if session_route?(params) do
      {session_id, requested_thread_id, session_pinned?} = resolve_session_context(params)

      socket =
        socket
        |> assign(:mode, :session)
        |> assign(:session_id, session_id)
        |> assign(:session_pinned?, session_pinned?)
        |> assign(:requested_thread_id, requested_thread_id)
        |> assign(:codex_status, :booting)
        |> assign(:thread_id, nil)
        |> assign(:active_turn_id, nil)
        |> assign(:active_turn_started_at_ms, nil)
        |> assign(:last_turn_elapsed_ms, nil)
        |> assign(:now_ms, System.system_time(:millisecond))
        |> assign(:token_usage, nil)
        |> assign(:rate_limits, nil)
        |> assign(:auth, nil)
        |> assign(:runtime, nil)
        |> assign(:session_stats, empty_session_stats())
        |> assign(:sessions, [])
        |> assign(:follow_tail?, true)
        |> assign(:prompt_form, to_form(%{"prompt" => ""}, as: :codex))
        |> stream_configure(:entries, dom_id: &entry_dom_id/1)
        |> stream(:entries, [], reset: true)

      socket =
        if connected?(socket) do
          Span.execute([:froth, :web, :mount_connected], nil, %{
            session_id: session_id,
            requested_thread_id: requested_thread_id
          })

          Process.send_after(self(), :tick, 1_000)

          socket
          |> connect_to_session()
          |> maybe_pin_session_url()
        else
          socket
        end

      {:ok, socket, layout: {FrothWeb.Layouts, :mini}}
    else
      socket =
        socket
        |> assign(:mode, :index)
        |> assign(:session_id, nil)
        |> assign(:session_pinned?, true)
        |> assign(:requested_thread_id, nil)
        |> assign(:codex_status, :ready)
        |> assign(:thread_id, nil)
        |> assign(:active_turn_id, nil)
        |> assign(:active_turn_started_at_ms, nil)
        |> assign(:last_turn_elapsed_ms, nil)
        |> assign(:now_ms, System.system_time(:millisecond))
        |> assign(:token_usage, nil)
        |> assign(:rate_limits, nil)
        |> assign(:auth, nil)
        |> assign(:runtime, nil)
        |> assign(:session_stats, empty_session_stats())
        |> assign(:follow_tail?, true)
        |> assign(:prompt_form, to_form(%{"prompt" => ""}, as: :codex))
        |> assign(:sessions, list_sessions())
        |> stream_configure(:entries, dom_id: &entry_dom_id/1)
        |> stream(:entries, [], reset: true)

      {:ok, socket, layout: {FrothWeb.Layouts, :mini}}
    end
  end

  @impl true
  def handle_event("refresh_sessions", _, %{assigns: %{mode: :index}} = socket) do
    {:noreply, assign(socket, :sessions, list_sessions())}
  end

  def handle_event("new_session", _, %{assigns: %{mode: :index}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/froth/mini/codex/#{random_session_id()}")}
  end

  def handle_event("toggle_follow_tail", _, %{assigns: %{mode: :session}} = socket) do
    {:noreply, assign(socket, :follow_tail?, !socket.assigns.follow_tail?)}
  end

  def handle_event("send_prompt", %{"codex" => %{"prompt" => raw_prompt}}, socket) do
    prompt = String.trim(raw_prompt || "")

    socket =
      cond do
        prompt == "" ->
          socket

        true ->
          Span.execute([:froth, :web, :send_prompt], nil, %{
            session_id: socket.assigns.session_id
          })

          case CodexSession.send_prompt(socket.assigns.session_id, prompt) do
            :ok ->
              refresh_snapshot(socket)

            {:error, reason} ->
              socket
              |> put_flash(:error, "send failed: #{inspect(reason)}")
              |> refresh_snapshot()
          end
      end

    {:noreply, assign(socket, :prompt_form, to_form(%{"prompt" => ""}, as: :codex))}
  end

  def handle_event("new_thread", _, socket) do
    Span.execute([:froth, :web, :new_thread], nil, %{session_id: socket.assigns.session_id})

    case CodexSession.new_thread(socket.assigns.session_id) do
      :ok ->
        {:noreply, refresh_snapshot(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "new thread failed: #{inspect(reason)}")
         |> refresh_snapshot()}
    end
  end

  def handle_event("interrupt_turn", _, socket) do
    Span.execute([:froth, :web, :interrupt_turn], nil, %{session_id: socket.assigns.session_id})

    case CodexSession.interrupt_turn(socket.assigns.session_id) do
      :ok ->
        {:noreply, refresh_snapshot(socket)}

      {:error, reason} ->
        {:noreply,
         socket |> put_flash(:error, "interrupt failed: #{inspect(reason)}") |> refresh_snapshot()}
    end
  end

  def handle_event("close", _, socket) do
    {:noreply, push_event(socket, "tg-close", %{})}
  end

  @impl true
  def handle_info(
        {:codex_session_updated, session_id},
        %{assigns: %{mode: :session, session_id: session_id}} = socket
      ) do
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info({:codex_session_updated, _other_session_id}, socket) do
    {:noreply, socket}
  end

  def handle_info(:tick, %{assigns: %{mode: :session}} = socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, :now_ms, System.system_time(:millisecond))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <%= if @mode == :index do %>
        <div class="min-h-screen bg-[radial-gradient(circle_at_top,rgba(20,20,40,0.55),rgba(5,5,8,1)_48%)] px-4 py-6 text-zinc-100 md:px-6">
          <div class="mx-auto w-full max-w-4xl">
            <div class="mb-4 flex items-center justify-between gap-2">
              <div>
                <p class="text-[10px] uppercase tracking-[0.2em] text-cyan-300/80">Codex Live</p>
                <h1 class="text-[16px] text-zinc-100">Sessions</h1>
                <p class="text-[12px] text-zinc-400">Pick one session or start a new one.</p>
              </div>
              <div class="flex items-center gap-2">
                <button
                  id="codex-refresh-sessions"
                  phx-click="refresh_sessions"
                  class="min-h-9 rounded-full border border-zinc-700 bg-zinc-900/70 px-3 text-[11px] text-zinc-300 transition hover:border-zinc-500 hover:text-zinc-100"
                >
                  Refresh
                </button>
                <button
                  id="codex-new-session"
                  phx-click="new_session"
                  class="min-h-9 rounded-full border border-cyan-500/50 bg-cyan-500/15 px-3 text-[11px] text-cyan-100 transition hover:bg-cyan-500/25"
                >
                  New Session
                </button>
              </div>
            </div>

            <div
              :if={@sessions == []}
              class="rounded-2xl border border-zinc-800 bg-zinc-900/60 px-4 py-6 text-center text-[12px] text-zinc-400"
            >
              no persisted sessions yet
            </div>

            <div :if={@sessions != []} class="space-y-2">
              <.link
                :for={session <- @sessions}
                navigate={~p"/froth/mini/codex/#{session.session_id}"}
                class="block rounded-2xl border border-zinc-800 bg-zinc-900/60 px-4 py-3 transition hover:border-zinc-600 hover:bg-zinc-900/80"
              >
                <div class="flex items-center justify-between gap-3">
                  <p class="min-w-0 truncate text-[12px] text-zinc-100">{session.session_id}</p>
                  <span class="shrink-0 text-[11px] text-zinc-500">{session.last_seen_at}</span>
                </div>
                <p class="mt-1 line-clamp-2 text-[12px] text-zinc-400">
                  {session_preview_text(session)}
                </p>
              </.link>
            </div>
          </div>
        </div>
      <% else %>
        <div
          id="codex-live-viewer"
          phx-hook="ToolScroll"
          data-follow-mode={follow_mode(@follow_tail?)}
          class="mini-shell safe-top flex min-h-0 flex-col bg-[radial-gradient(circle_at_top,rgba(20,20,40,0.55),rgba(5,5,8,1)_48%)] text-zinc-100"
        >
          <header class="sticky top-0 z-30 border-b border-zinc-800/70 bg-zinc-950/92 backdrop-blur">
            <div class="mx-auto w-full max-w-3xl px-2 py-1.5">
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0 flex-1">
                  <div class="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-1 font-mono text-[10px]">
                    <span
                      :if={session_busy?(@codex_status, @active_turn_id)}
                      class="inline-flex items-center gap-1 text-amber-200/90"
                    >
                      <span>live</span>
                      <.working_dots />
                    </span>
                    <span class={modeline_status_class(@codex_status)}>
                      {modeline_status(@codex_status)}
                    </span>
                    <span class={modeline_state_class(@codex_status)}>
                      {modeline_state_text(@codex_status)}
                    </span>
                    <span class="text-zinc-500">Codex</span>
                    <span :if={modeline_model(@runtime)} class="text-sky-300">
                      {modeline_model(@runtime)}
                    </span>
                    <span :if={modeline_reasoning(@runtime)} class="text-amber-300/80">
                      {modeline_reasoning(@runtime)}
                    </span>
                    <span :if={modeline_sandbox(@runtime)} class={modeline_sandbox_class(@runtime)}>
                      {modeline_sandbox(@runtime)}
                    </span>
                    <span :if={modeline_tokens(@token_usage)} class="text-zinc-400">
                      {modeline_tokens(@token_usage)}
                    </span>
                    <span :if={rate_limit_badge(@rate_limits)} class="text-zinc-500">
                      {rate_limit_badge(@rate_limits)}
                    </span>
                    <span
                      :if={
                        elapsed_badge(
                          @active_turn_id,
                          @active_turn_started_at_ms,
                          @last_turn_elapsed_ms,
                          @now_ms
                        )
                      }
                      class="text-zinc-400"
                    >
                      {elapsed_badge(
                        @active_turn_id,
                        @active_turn_started_at_ms,
                        @last_turn_elapsed_ms,
                        @now_ms
                      )}
                    </span>
                    <span :if={tool_progress_badge(@session_stats)} class="text-zinc-500">
                      {tool_progress_badge(@session_stats)}
                    </span>
                  </div>
                </div>
                <div class="flex shrink-0 items-center gap-1.5">
                  <label class="mini-toggle" data-active={to_string(@follow_tail?)}>
                    <input
                      id="codex-follow-tail"
                      type="checkbox"
                      checked={@follow_tail?}
                      phx-click="toggle_follow_tail"
                    />
                    <span>Latest</span>
                  </label>
                  <button id="codex-close" phx-click="close" class="mini-btn mini-btn--icon">
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </div>
            </div>
          </header>

          <main
            id="tool-feed"
            data-scroll-body
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-1.5 py-1.5"
          >
            <div
              id="codex-feed-list"
              phx-update="stream"
              class="mx-auto w-full max-w-3xl space-y-1.5"
            >
              <div :for={{dom_id, entry} <- @streams.entries} id={dom_id}>
                <%= cond do %>
                  <% entry.kind == :user -> %>
                    <.codex_message body={entry.body} tone={:user} />
                  <% entry.kind == :assistant -> %>
                    <.codex_message body={entry.body} tone={:assistant} />
                  <% entry.kind == :tool -> %>
                    <.codex_tool_entry entry={entry} />
                  <% entry.kind == :reasoning -> %>
                    <details class="max-w-[98%] rounded-xl border border-zinc-800/80 bg-zinc-950/45 px-2 py-1.5">
                      <summary class="cursor-pointer list-none select-none text-[10px] uppercase tracking-[0.14em] text-zinc-500 hover:text-zinc-300 [&::-webkit-details-marker]:hidden">
                        reasoning
                      </summary>
                      <pre class="mt-1 whitespace-pre-wrap font-mono text-[11px] leading-5 text-zinc-500">{entry.body}</pre>
                    </details>
                  <% entry.kind == :error -> %>
                    <div class="max-w-[98%] whitespace-pre-wrap rounded-xl border border-rose-500/45 bg-rose-950/35 px-2.5 py-2 text-[12px] leading-5 text-rose-100">
                      {entry.body}
                    </div>
                  <% true -> %>
                    <.codex_status_entry entry={entry} />
                <% end %>
              </div>

              <div id="tool-feed-end" data-scroll-end></div>
            </div>
          </main>

          <div
            id="codex-now-dock"
            class="safe-bottom border-t border-zinc-800/80 bg-zinc-950/95 backdrop-blur"
          >
            <div class="mx-auto w-full max-w-3xl px-2 py-2">
              <div class="mb-1.5 flex items-center justify-between gap-2">
                <div class="min-w-0 truncate font-sans text-[11px] text-zinc-400">
                  {session_footer_text(@codex_status, @active_turn_id, @thread_id)}
                </div>
                <div class="flex shrink-0 items-center gap-1.5">
                  <button id="codex-new-thread" phx-click="new_thread" class="mini-btn">
                    New Thread
                  </button>
                  <button
                    :if={is_binary(@active_turn_id)}
                    id="codex-interrupt"
                    phx-click="interrupt_turn"
                    class="mini-btn mini-btn--warn"
                  >
                    Interrupt
                  </button>
                </div>
              </div>

              <.form
                for={@prompt_form}
                id="codex-prompt-form"
                phx-submit="send_prompt"
                class="flex items-end gap-2 pb-[calc(0.2rem+var(--kb,0px))]"
              >
                <.input
                  field={@prompt_form[:prompt]}
                  type="textarea"
                  rows="1"
                  placeholder="Ask Codex..."
                  enterkeyhint="send"
                  class="mini-input min-h-[2.75rem] resize-none"
                />
                <button
                  id="codex-send"
                  type="submit"
                  class="mini-btn mini-btn--accent min-h-[2.75rem]"
                >
                  Send
                </button>
              </.form>
            </div>
          </div>

          <div
            :if={@codex_status == :error}
            class="border-t border-rose-900/70 bg-rose-950/40 px-3 py-1.5 text-[10px] text-rose-200"
          >
            codex session is in an error state; check the latest error card for details.
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :body, :string, required: true
  attr :tone, :atom, required: true

  defp codex_message(assigns) do
    {text, footer} = split_cost_footer(assigns.body)

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:footer, footer)
      |> assign(:html, render_markdown_html(text))

    ~H"""
    <%= if @text do %>
      <div class={codex_message_class(@tone)}>
        <div class={codex_message_text_class(@tone)}>
          {raw(@html)}
        </div>
        <div :if={@footer} class="mt-1.5">
          <.metadata_footer footer={@footer} />
        </div>
      </div>
    <% else %>
      <div :if={@footer} class="max-w-[96%]">
        <.metadata_footer footer={@footer} />
      </div>
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

  attr :entry, :map, required: true

  defp codex_tool_entry(assigns) do
    ~H"""
    <div class={codex_tool_card_class(@entry.status)}>
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-1.5">
            <.icon name="hero-command-line" class="size-3.5 shrink-0 text-sky-300/90" />
            <p class="text-[10px] uppercase tracking-[0.12em] text-sky-200/80">Tool</p>
          </div>
          <pre class="mt-1 overflow-x-auto whitespace-pre-wrap rounded-lg border border-zinc-800/80 bg-black/20 px-2 py-1.5 font-mono text-[11px] leading-5 text-zinc-100">{@entry.body}</pre>
          <div
            :if={@entry.status == "running"}
            class="mt-1 inline-flex items-center gap-1 font-mono text-[10px] text-amber-200/85"
          >
            <span>running</span>
            <.working_dots />
          </div>
        </div>
        <span class={tool_status_chip_class(@entry.status)}>
          {tool_status_text(@entry.status)}
        </span>
      </div>

      <details
        :if={is_binary(@entry.output) and @entry.output != ""}
        class="mt-1.5 rounded-lg border border-zinc-800/80 bg-black/15"
      >
        <summary class="cursor-pointer list-none px-2 py-1 text-[10px] font-medium uppercase tracking-[0.14em] text-zinc-400 [&::-webkit-details-marker]:hidden">
          Output
        </summary>
        <div class="border-t border-zinc-800/80 px-2 py-2">
          <pre class="max-h-56 overflow-auto whitespace-pre-wrap font-mono text-[11px] leading-5 text-zinc-200">{@entry.output}</pre>
        </div>
      </details>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp codex_status_entry(assigns) do
    descriptor = status_entry_descriptor(assigns.entry)

    assigns =
      assigns
      |> assign(:descriptor, descriptor)

    ~H"""
    <div class={status_entry_class(@descriptor.tone)}>
      <div class="flex flex-wrap items-center gap-1.5">
        <span class={status_entry_badge_class(@descriptor.tone)}>{@descriptor.badge}</span>
        <p class="font-sans text-[12px] leading-5 text-zinc-100">{@descriptor.title}</p>
        <.working_dots :if={@descriptor.spinner?} class="text-amber-200/85" />
      </div>

      <p :if={@descriptor.subtitle} class="mt-0.5 font-sans text-[12px] leading-5 text-zinc-400">
        {@descriptor.subtitle}
      </p>

      <div :if={@descriptor.plan_steps != []} class="mt-2 space-y-1">
        <div
          :for={step <- @descriptor.plan_steps}
          class="flex items-start gap-2 rounded-lg border border-zinc-800/80 bg-black/15 px-2 py-1.5"
        >
          <span class={plan_step_badge_class(step.status)}>
            {plan_step_status_text(step.status)}
          </span>
          <p class="min-w-0 flex-1 text-[12px] leading-5 text-zinc-200">{step.step}</p>
        </div>
      </div>

      <details
        :if={@descriptor.details}
        class="mt-1 rounded-lg border border-zinc-800/80 bg-black/15"
      >
        <summary class="cursor-pointer list-none px-2 py-1 text-[10px] font-medium uppercase tracking-[0.14em] text-zinc-400 [&::-webkit-details-marker]:hidden">
          Details
        </summary>
        <div class="border-t border-zinc-800/80 px-2 py-2">
          <pre class="max-h-48 overflow-auto whitespace-pre-wrap font-mono text-[11px] leading-5 text-zinc-400">{@descriptor.details}</pre>
        </div>
      </details>
    </div>
    """
  end

  defp connect_to_session(socket) do
    opts =
      case socket.assigns.requested_thread_id do
        thread_id when is_binary(thread_id) -> [thread_id: thread_id]
        _ -> []
      end

    with {:ok, _pid} <- CodexSession.ensure_started(socket.assigns.session_id, opts),
         :ok <- CodexSession.subscribe(socket.assigns.session_id),
         {:ok, snapshot} <- CodexSession.snapshot(socket.assigns.session_id) do
      apply_snapshot(socket, snapshot)
    else
      {:error, reason} ->
        Span.execute([:froth, :web, :connect_failed], nil, %{
          session_id: socket.assigns.session_id,
          reason: inspect(reason)
        })

        socket
        |> assign(:codex_status, :error)
        |> put_flash(:error, "failed to connect: #{inspect(reason)}")
    end
  end

  defp maybe_pin_session_url(%{assigns: %{session_pinned?: true}} = socket), do: socket

  defp maybe_pin_session_url(socket) do
    push_navigate(socket, to: ~p"/froth/mini/codex/#{socket.assigns.session_id}")
  end

  defp refresh_snapshot(socket) do
    case CodexSession.snapshot(socket.assigns.session_id) do
      {:ok, snapshot} ->
        apply_snapshot(socket, snapshot)

      {:error, reason} ->
        Span.execute([:froth, :web, :snapshot_failed], nil, %{
          session_id: socket.assigns.session_id,
          reason: inspect(reason)
        })

        socket
        |> assign(:codex_status, :error)
        |> put_flash(:error, "snapshot failed: #{inspect(reason)}")
    end
  end

  defp apply_snapshot(socket, snapshot) when is_map(snapshot) do
    entries = normalize_entries(Map.get(snapshot, :entries) || Map.get(snapshot, "entries"))

    socket
    |> assign(
      :codex_status,
      Map.get(snapshot, :status) || Map.get(snapshot, "status") || :unknown
    )
    |> assign(:thread_id, Map.get(snapshot, :thread_id) || Map.get(snapshot, "thread_id"))
    |> assign(
      :active_turn_id,
      Map.get(snapshot, :active_turn_id) || Map.get(snapshot, "active_turn_id")
    )
    |> assign(
      :active_turn_started_at_ms,
      normalize_optional_integer(
        Map.get(snapshot, :active_turn_started_at_ms) ||
          Map.get(snapshot, "active_turn_started_at_ms")
      )
    )
    |> assign(
      :last_turn_elapsed_ms,
      normalize_optional_integer(
        Map.get(snapshot, :last_turn_elapsed_ms) || Map.get(snapshot, "last_turn_elapsed_ms")
      )
    )
    |> assign(:token_usage, Map.get(snapshot, :token_usage) || Map.get(snapshot, "token_usage"))
    |> assign(:rate_limits, Map.get(snapshot, :rate_limits) || Map.get(snapshot, "rate_limits"))
    |> assign(:auth, Map.get(snapshot, :auth) || Map.get(snapshot, "auth"))
    |> assign(:runtime, Map.get(snapshot, :runtime) || Map.get(snapshot, "runtime"))
    |> assign(:session_stats, build_session_stats(entries))
    |> stream(:entries, entries, reset: true)
  end

  defp normalize_entries(entries) when is_list(entries) do
    Enum.map(entries, &normalize_entry/1)
  end

  defp normalize_entries(_), do: []

  defp normalize_entry(entry) when is_map(entry) do
    id = Map.get(entry, :id) || Map.get(entry, "id") || "entry-#{:erlang.phash2(entry)}"
    kind = Map.get(entry, :kind) || Map.get(entry, "kind")
    body = Map.get(entry, :body) || Map.get(entry, "body") || ""
    status = Map.get(entry, :status) || Map.get(entry, "status")
    output = Map.get(entry, :output) || Map.get(entry, "output")
    label = Map.get(entry, :label) || Map.get(entry, "label")
    sequence = Map.get(entry, :sequence) || Map.get(entry, "sequence")

    %{
      id: to_string(id),
      kind: normalize_entry_kind(kind),
      body: to_string(body),
      status: normalize_optional_text(status),
      output: normalize_optional_text(output),
      label: normalize_optional_text(label),
      sequence: normalize_optional_sequence(sequence)
    }
  end

  defp normalize_entry(other),
    do: %{id: "entry-#{:erlang.phash2(other)}", kind: :event, body: inspect(other)}

  defp normalize_entry_kind(kind)
       when kind in [:assistant, :error, :event, :reasoning, :status, :system, :tool, :user],
       do: kind

  defp normalize_entry_kind(kind) when is_binary(kind),
    do: Map.get(@entry_kinds, kind, :event)

  defp normalize_entry_kind(_), do: :event

  defp normalize_optional_text(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_text(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_text(_), do: nil

  defp normalize_optional_sequence(value) when is_integer(value), do: value

  defp normalize_optional_sequence(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_sequence(_), do: nil

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_), do: nil

  defp empty_session_stats, do: %{tool_total: 0, tool_completed: 0, tool_running: 0}

  defp build_session_stats(entries) when is_list(entries) do
    Enum.reduce(entries, empty_session_stats(), fn
      %{kind: :tool, status: status}, stats ->
        stats
        |> Map.update!(:tool_total, &(&1 + 1))
        |> maybe_increment_completed(status)
        |> maybe_increment_running(status)

      _, stats ->
        stats
    end)
  end

  defp build_session_stats(_), do: empty_session_stats()

  defp maybe_increment_completed(stats, status) when status in ["ok", "done", "error"],
    do: Map.update!(stats, :tool_completed, &(&1 + 1))

  defp maybe_increment_completed(stats, _status), do: stats

  defp maybe_increment_running(stats, "running"),
    do: Map.update!(stats, :tool_running, &(&1 + 1))

  defp maybe_increment_running(stats, _status), do: stats

  defp codex_message_class(:assistant),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/70 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp codex_message_class(:user),
    do:
      "ml-auto max-w-[96%] rounded-[0.9rem] border border-emerald-500/30 bg-emerald-500/10 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp codex_message_class(_),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/70 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp codex_message_text_class(:assistant),
    do: "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-zinc-100"

  defp codex_message_text_class(:user),
    do:
      "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-right text-emerald-50 [&_*]:text-right"

  defp codex_message_text_class(_),
    do: "mini-markdown md-prose font-sans text-[13px] leading-[1.48] text-zinc-100"

  defp follow_mode(true), do: "always"
  defp follow_mode(false), do: "manual"
  defp follow_mode(_), do: "always"

  defp codex_tool_card_class("error"),
    do:
      "max-w-[98%] rounded-[0.9rem] border border-rose-500/35 bg-rose-950/30 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"

  defp codex_tool_card_class("running"),
    do:
      "max-w-[98%] rounded-[0.9rem] border border-amber-500/30 bg-amber-950/20 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"

  defp codex_tool_card_class(_),
    do:
      "max-w-[98%] rounded-[0.9rem] border border-sky-900/60 bg-sky-950/20 px-2.5 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"

  defp status_entry_descriptor(entry) when is_map(entry) do
    body = blank_to_nil(entry.body) || "update"
    details = blank_to_nil(entry.output)
    subtitle = blank_to_nil(entry.label)

    cond do
      received = parse_received_status(body, details, subtitle) ->
        received

      String.starts_with?(body, "working") ->
        turn_id =
          case Regex.run(~r/\(([^)]+)\)/, body, capture: :all_but_first) do
            [id] -> id
            _ -> nil
          end

        %{
          badge: "turn",
          tone: :warning,
          title: "Turn running",
          subtitle: turn_id,
          details: nil,
          plan_steps: [],
          spinner?: true
        }

      String.starts_with?(body, "turn ") ->
        turn_status = String.replace_prefix(body, "turn ", "")

        %{
          badge: "turn",
          tone: if(turn_status in ["completed", "done"], do: :success, else: :neutral),
          title: "Turn #{turn_status}",
          subtitle: subtitle,
          details: details,
          plan_steps: [],
          spinner?: false
        }

      String.starts_with?(body, "thread started ") ->
        %{
          badge: "thread",
          tone: :success,
          title: "Thread started",
          subtitle: String.replace_prefix(body, "thread started ", ""),
          details: details,
          plan_steps: [],
          spinner?: false
        }

      String.starts_with?(body, "thread ready ") ->
        %{
          badge: "thread",
          tone: :success,
          title: "Thread ready",
          subtitle: String.replace_prefix(body, "thread ready ", ""),
          details: details,
          plan_steps: [],
          spinner?: false
        }

      String.starts_with?(body, "resumed thread ") ->
        %{
          badge: "thread",
          tone: :success,
          title: "Thread resumed",
          subtitle: String.replace_prefix(body, "resumed thread ", ""),
          details: details,
          plan_steps: [],
          spinner?: false
        }

      true ->
        %{
          badge: entry_badge(entry.kind),
          tone: entry_tone(entry.kind),
          title: body,
          subtitle: subtitle,
          details: details,
          plan_steps: [],
          spinner?: false
        }
    end
  end

  defp status_entry_descriptor(_),
    do: %{
      badge: "status",
      tone: :neutral,
      title: "update",
      subtitle: nil,
      details: nil,
      plan_steps: [],
      spinner?: false
    }

  defp parse_received_status(body, details, subtitle) when is_binary(body) do
    case Regex.run(~r/^received\s+([^\s]+)\s*(.*)$/s, body, capture: :all_but_first) do
      [method, raw] ->
        plan_steps = protocol_plan_steps(raw)

        %{
          badge: if(String.contains?(method, "plan"), do: "plan", else: "event"),
          tone: protocol_tone(method, plan_steps),
          title: protocol_title(method),
          subtitle: protocol_summary(method, raw) || subtitle,
          details: blank_to_nil(raw) || details,
          plan_steps: plan_steps,
          spinner?: false
        }

      _ ->
        nil
    end
  end

  defp parse_received_status(_body, _details, _subtitle), do: nil

  defp protocol_title("turn/plan/updated"), do: "Plan updated"
  defp protocol_title("turn/updated"), do: "Turn updated"

  defp protocol_title(method) when is_binary(method) do
    method
    |> String.split(~r{[/_]+}, trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp protocol_title(_), do: "Event"

  defp protocol_summary(method, raw) when is_binary(raw) and raw != "" do
    cond do
      String.contains?(method, "plan") ->
        extract_quoted_value(raw, "EXPLANATION")

      true ->
        extract_quoted_value(raw, "message") || extract_quoted_value(raw, "status")
    end
  end

  defp protocol_summary(_method, _raw), do: nil

  defp protocol_tone(method, plan_steps) when is_binary(method) and is_list(plan_steps) do
    cond do
      Enum.any?(plan_steps, &(&1.status == "in_progress")) -> :warning
      String.contains?(method, "plan") -> :neutral
      String.contains?(method, "updated") -> :neutral
      true -> :neutral
    end
  end

  defp protocol_tone(_method, _plan_steps), do: :neutral

  defp protocol_plan_steps(raw) when is_binary(raw) do
    ~r/%\{([^{}]+)\}/s
    |> Regex.scan(raw, capture: :all_but_first)
    |> Enum.map(fn [chunk] ->
      %{
        step: extract_quoted_value(chunk, "step"),
        status: extract_quoted_value(chunk, "status")
      }
    end)
    |> Enum.filter(&(is_binary(&1.step) and String.trim(&1.step) != ""))
  end

  defp protocol_plan_steps(_), do: []

  defp extract_quoted_value(text, key) when is_binary(text) and is_binary(key) do
    pattern = ~r/"#{Regex.escape(key)}"\s*=>\s*"([^"]+)"/

    case Regex.run(pattern, text, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end

  defp extract_quoted_value(_text, _key), do: nil

  defp entry_badge(:system), do: "system"
  defp entry_badge(:status), do: "status"
  defp entry_badge(:event), do: "event"
  defp entry_badge(_), do: "status"

  defp entry_tone(:system), do: :neutral
  defp entry_tone(:status), do: :neutral
  defp entry_tone(:event), do: :neutral
  defp entry_tone(_), do: :neutral

  defp status_entry_class(:warning),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-amber-500/25 bg-amber-950/20 px-2.5 py-1.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp status_entry_class(:success),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-emerald-500/25 bg-emerald-950/20 px-2.5 py-1.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp status_entry_class(:error),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-rose-500/25 bg-rose-950/20 px-2.5 py-1.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp status_entry_class(_),
    do:
      "max-w-[96%] rounded-[0.9rem] border border-zinc-800/80 bg-zinc-950/70 px-2.5 py-1.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.02)]"

  defp status_entry_badge_class(:warning),
    do:
      "inline-flex items-center rounded-full border border-amber-500/35 bg-amber-500/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.14em] text-amber-200"

  defp status_entry_badge_class(:success),
    do:
      "inline-flex items-center rounded-full border border-emerald-500/35 bg-emerald-500/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.14em] text-emerald-200"

  defp status_entry_badge_class(:error),
    do:
      "inline-flex items-center rounded-full border border-rose-500/35 bg-rose-500/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.14em] text-rose-200"

  defp status_entry_badge_class(_),
    do:
      "inline-flex items-center rounded-full border border-zinc-700/80 bg-zinc-900/80 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.14em] text-zinc-400"

  defp plan_step_badge_class("completed"),
    do:
      "inline-flex shrink-0 items-center rounded-full border border-emerald-500/35 bg-emerald-500/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.12em] text-emerald-200"

  defp plan_step_badge_class("in_progress"),
    do:
      "inline-flex shrink-0 items-center rounded-full border border-amber-500/35 bg-amber-500/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.12em] text-amber-200"

  defp plan_step_badge_class("pending"),
    do:
      "inline-flex shrink-0 items-center rounded-full border border-zinc-700/80 bg-zinc-900/80 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.12em] text-zinc-400"

  defp plan_step_badge_class(_),
    do:
      "inline-flex shrink-0 items-center rounded-full border border-sky-500/35 bg-sky-500/10 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-[0.12em] text-sky-200"

  defp plan_step_status_text("completed"), do: "done"
  defp plan_step_status_text("in_progress"), do: "active"
  defp plan_step_status_text("pending"), do: "queued"
  defp plan_step_status_text(status) when is_binary(status), do: status
  defp plan_step_status_text(_), do: "step"

  defp tool_status_chip_class("running"),
    do:
      "inline-flex items-center rounded-full border border-amber-500/35 bg-amber-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-amber-200"

  defp tool_status_chip_class("ok"),
    do:
      "inline-flex items-center rounded-full border border-emerald-500/35 bg-emerald-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-emerald-200"

  defp tool_status_chip_class("error"),
    do:
      "inline-flex items-center rounded-full border border-rose-500/35 bg-rose-500/10 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-rose-200"

  defp tool_status_chip_class(_),
    do:
      "inline-flex items-center rounded-full border border-zinc-700/80 bg-zinc-900/80 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-zinc-400"

  defp tool_status_text("running"), do: "running"
  defp tool_status_text("ok"), do: "done"
  defp tool_status_text("error"), do: "error"
  defp tool_status_text("done"), do: "done"
  defp tool_status_text(_), do: "update"

  defp rate_limit_badge(rate_limits) when is_map(rate_limits) do
    primary_used =
      get_in(rate_limits, ["primary", "usedPercent"]) ||
        get_in(rate_limits, [:primary, :usedPercent])

    secondary_used =
      get_in(rate_limits, ["secondary", "usedPercent"]) ||
        get_in(rate_limits, [:secondary, :usedPercent])

    cond do
      is_integer(primary_used) and is_integer(secondary_used) ->
        "limits #{primary_used}% / #{secondary_used}%"

      is_integer(primary_used) ->
        "limits #{primary_used}%"

      true ->
        nil
    end
  end

  defp rate_limit_badge(_), do: nil

  # --- Modeline helpers (compact header) ---

  defp modeline_status(:ready), do: "\u25cf"
  defp modeline_status(:working), do: "\u25c9"
  defp modeline_status(:error), do: "\u2715"
  defp modeline_status(_), do: "\u25cb"

  defp modeline_status_class(:ready), do: "text-emerald-400"
  defp modeline_status_class(:working), do: "text-amber-400 animate-pulse"
  defp modeline_status_class(:error), do: "text-rose-400"
  defp modeline_status_class(_), do: "text-zinc-500"

  defp modeline_state_text(:working), do: "working"
  defp modeline_state_text(:ready), do: "ready"
  defp modeline_state_text(:error), do: "error"
  defp modeline_state_text(:booting), do: "booting"
  defp modeline_state_text(_), do: "idle"

  defp modeline_state_class(:working), do: "text-amber-200"
  defp modeline_state_class(:ready), do: "text-emerald-200"
  defp modeline_state_class(:error), do: "text-rose-200"
  defp modeline_state_class(_), do: "text-zinc-400"

  defp modeline_model(runtime) when is_map(runtime), do: runtime_field(runtime, :model, "model")
  defp modeline_model(_), do: nil

  defp modeline_reasoning(runtime) when is_map(runtime),
    do: runtime_field(runtime, :reasoning_effort, "reasoning_effort")

  defp modeline_reasoning(_), do: nil

  defp modeline_sandbox(runtime) when is_map(runtime) do
    raw = runtime_field(runtime, :sandbox, "sandbox")

    cond do
      is_binary(raw) and String.contains?(raw, "dangerFullAccess") -> "yolo"
      is_binary(raw) and String.contains?(raw, "danger") -> "yolo"
      is_binary(raw) and String.contains?(raw, "workspace") -> "sandbox"
      is_binary(raw) -> String.slice(raw, 0, 12)
      true -> nil
    end
  end

  defp modeline_sandbox(_), do: nil

  defp modeline_sandbox_class(runtime) when is_map(runtime) do
    raw = runtime_field(runtime, :sandbox, "sandbox")

    if is_binary(raw) and (String.contains?(raw, "danger") or String.contains?(raw, "Full")) do
      "text-rose-400/80"
    else
      "text-zinc-500"
    end
  end

  defp modeline_sandbox_class(_), do: "text-zinc-500"

  defp modeline_tokens(token_usage) when is_map(token_usage) do
    last =
      get_in(token_usage, ["last", "totalTokens"]) || get_in(token_usage, [:last, :totalTokens])

    total =
      get_in(token_usage, ["total", "totalTokens"]) || get_in(token_usage, [:total, :totalTokens])

    cond do
      is_integer(last) and is_integer(total) -> "#{format_k(last)}/#{format_k(total)}"
      is_integer(total) -> format_k(total)
      is_integer(last) -> format_k(last)
      true -> nil
    end
  end

  defp modeline_tokens(_), do: nil

  defp elapsed_badge(active_turn_id, started_at_ms, _last_turn_elapsed_ms, now_ms)
       when is_binary(active_turn_id) and is_integer(started_at_ms) and is_integer(now_ms) do
    format_elapsed_ms(max(now_ms - started_at_ms, 0))
  end

  defp elapsed_badge(_active_turn_id, _started_at_ms, last_turn_elapsed_ms, _now_ms)
       when is_integer(last_turn_elapsed_ms) do
    "last #{format_elapsed_ms(last_turn_elapsed_ms)}"
  end

  defp elapsed_badge(_active_turn_id, _started_at_ms, _last_turn_elapsed_ms, _now_ms), do: nil

  defp tool_progress_badge(%{tool_total: 0}), do: nil

  defp tool_progress_badge(%{tool_total: total, tool_completed: completed, tool_running: running})
       when running > 0 do
    "#{completed}/#{total} tools"
  end

  defp tool_progress_badge(%{tool_total: total}), do: "#{total} tools"

  defp tool_progress_badge(_), do: nil

  defp format_elapsed_ms(ms) when is_integer(ms) and ms >= 60_000 do
    total_seconds = div(ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}m#{seconds}s"
  end

  defp format_elapsed_ms(ms) when is_integer(ms) and ms >= 0 do
    "#{Float.round(ms / 1_000, 1)}s"
  end

  defp format_elapsed_ms(_), do: nil

  defp format_k(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_k(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_k(n), do: "#{n}"

  defp session_busy?(status, active_turn_id),
    do: status in [:booting, :working] or is_binary(active_turn_id)

  defp session_footer_text(_status, active_turn_id, _thread_id) when is_binary(active_turn_id),
    do: "Turn #{String.slice(active_turn_id, 0, 12)} is live"

  defp session_footer_text(:error, _active_turn_id, _thread_id), do: "Session needs attention"
  defp session_footer_text(:booting, _active_turn_id, _thread_id), do: "Connecting to Codex"

  defp session_footer_text(_status, _active_turn_id, thread_id) when is_binary(thread_id),
    do: "Thread #{String.slice(thread_id, 0, 12)} ready"

  defp session_footer_text(_status, _active_turn_id, _thread_id), do: "Ready"

  defp split_cost_footer(text) when is_binary(text) do
    trimmed = String.trim(text)

    case Regex.run(
           ~r/^(.*?)(?:\n{2,}|\n)?(\[[0-9]+(?:\.[0-9]+)?s \| [^\]\n]+ in \| [^\]\n]+ out \| \$[0-9]+(?:\.[0-9]+)?\])$/s,
           trimmed,
           capture: :all_but_first
         ) do
      [body, footer] -> {blank_to_nil(body), footer}
      _ -> {blank_to_nil(trimmed), nil}
    end
  end

  defp split_cost_footer(_), do: {nil, nil}

  defp render_markdown_html(text) when is_binary(text) do
    options = %Earmark.Options{
      breaks: true,
      code_class_prefix: "language-",
      escape: true,
      smartypants: false
    }

    case Earmark.as_html(text, options) do
      {:ok, html, _} -> html
      {:error, html, _} -> html
      _ -> text |> html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  defp render_markdown_html(_), do: ""

  defp runtime_field(runtime, atom_key, string_key) when is_map(runtime) do
    Map.get(runtime, atom_key) || Map.get(runtime, string_key)
  end

  defp runtime_field(_runtime, _atom_key, _string_key), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp entry_dom_id(%{id: id}) when is_binary(id), do: id
  defp entry_dom_id(_), do: "entry"

  defp session_route?(params) when is_map(params) do
    is_binary(normalize_session_id(params["session_id"])) ||
      is_binary(normalize_thread_id(params["thread_id"])) ||
      is_binary(normalize_thread_id(params["tgWebAppStartParam"])) ||
      is_binary(normalize_session_id(params["tgWebAppStartParam"]))
  end

  defp session_route?(_), do: false

  defp list_sessions do
    CodexEvents.list_sessions(120)
    |> Enum.map(fn session ->
      %{
        session_id: session.session_id,
        last_seen_at: format_last_seen(session.last_seen_at),
        last_kind: session.last_kind,
        last_body: session.last_body
      }
    end)
  end

  defp session_preview_text(session) when is_map(session) do
    kind = session[:last_kind] || session["last_kind"] || "event"
    body = session[:last_body] || session["last_body"] || "no details yet"
    truncate("#{kind}: #{body}", 240)
  end

  defp format_last_seen(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_last_seen(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_last_seen(_), do: "-"

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 0 do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp resolve_session_context(params) when is_map(params) do
    explicit_session_id = normalize_session_id(params["session_id"])
    tg_start_param = normalize_session_id(params["tgWebAppStartParam"])

    requested_thread_id =
      normalize_thread_id(params["thread_id"]) ||
        normalize_thread_id(params["tgWebAppStartParam"]) ||
        normalize_thread_id(params["session_id"])

    session_id =
      explicit_session_id ||
        tg_start_param ||
        requested_thread_id ||
        random_session_id()

    {session_id, requested_thread_id, is_binary(explicit_session_id)}
  end

  defp resolve_session_context(_params), do: {random_session_id(), nil, false}

  defp normalize_session_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_session_id(_), do: nil

  defp normalize_thread_id(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "thread_") ->
        suffix = String.replace_prefix(value, "thread_", "")
        if String.starts_with?(suffix, "thr_"), do: suffix, else: nil

      String.starts_with?(value, "thr_") ->
        value

      true ->
        nil
    end
  end

  defp normalize_thread_id(_), do: nil

  defp random_session_id do
    "s_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end
end
