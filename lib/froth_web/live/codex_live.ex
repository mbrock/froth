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
        |> assign(:token_usage, nil)
        |> assign(:rate_limits, nil)
        |> assign(:auth, nil)
        |> assign(:runtime, nil)
        |> assign(:sessions, [])
        |> assign(:prompt_form, to_form(%{"prompt" => ""}, as: :codex))
        |> stream_configure(:entries, dom_id: &entry_dom_id/1)
        |> stream(:entries, [], reset: true)

      socket =
        if connected?(socket) do
          Span.execute([:froth, :web, :mount_connected], nil, %{
            session_id: session_id,
            requested_thread_id: requested_thread_id
          })

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
        |> assign(:token_usage, nil)
        |> assign(:rate_limits, nil)
        |> assign(:auth, nil)
        |> assign(:runtime, nil)
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
          data-follow-mode={follow_mode(@active_turn_id)}
          class="flex min-h-screen flex-col bg-[radial-gradient(circle_at_top,rgba(20,20,40,0.55),rgba(5,5,8,1)_48%)] text-[13px] text-zinc-100"
        >
          <header class="sticky top-0 z-30 border-b border-zinc-800/70 bg-zinc-950/90 backdrop-blur">
            <div class="mx-auto w-full max-w-5xl px-3 py-2.5 md:px-5">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0 space-y-0.5">
                  <p class="text-[10px] uppercase tracking-[0.2em] text-cyan-300/80">Codex Live</p>
                  <h1 class="truncate text-[12px] text-zinc-100">session {@session_id}</h1>
                  <p class="truncate text-[11px] text-zinc-400">
                    thread: {display_thread(@thread_id)}
                  </p>
                </div>

                <div class="flex items-center gap-1.5">
                  <span class={status_chip_class(@codex_status)}>
                    {status_text(@codex_status)}
                  </span>
                  <button
                    id="codex-close"
                    phx-click="close"
                    class="inline-flex min-h-8 items-center rounded-md border border-zinc-700 bg-zinc-900/75 px-2.5 text-[10px] uppercase tracking-[0.08em] text-zinc-300 transition hover:border-zinc-500 hover:text-zinc-100"
                  >
                    Close
                  </button>
                </div>
              </div>
              <div class="mt-2 flex flex-wrap items-center gap-1.5">
                <span
                  :if={auth_badge(@auth)}
                  class={auth_chip_class(@auth)}
                >
                  {auth_badge(@auth)}
                </span>
                <span
                  :for={badge <- runtime_badges(@runtime)}
                  class={runtime_chip_class(badge)}
                >
                  {badge}
                </span>
                <span
                  :if={is_binary(@active_turn_id)}
                  class="inline-flex items-center rounded-md border border-cyan-800/70 bg-cyan-950/30 px-1.5 py-0.5 text-[10px] text-cyan-300"
                >
                  turn {short_id(@active_turn_id)}
                </span>
                <span
                  :if={token_usage_badge(@token_usage)}
                  class="inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/75 px-1.5 py-0.5 text-[10px] text-zinc-300"
                >
                  {token_usage_badge(@token_usage)}
                </span>
                <span
                  :if={rate_limit_badge(@rate_limits)}
                  class="inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/75 px-1.5 py-0.5 text-[10px] text-zinc-300"
                >
                  {rate_limit_badge(@rate_limits)}
                </span>
              </div>
            </div>
          </header>

          <main id="tool-feed" class="flex-1 overflow-y-auto px-3 py-2.5 md:px-5">
            <div class="mx-auto w-full max-w-5xl space-y-1.5 font-mono">
              <div :for={{dom_id, entry} <- @streams.entries} id={dom_id}>
                <%= cond do %>
                  <% entry.kind == :user -> %>
                    <div class="ml-auto max-w-[95%] whitespace-pre-wrap rounded-lg border border-emerald-500/35 bg-emerald-500/10 px-3 py-1.5 text-[12px] leading-5 text-emerald-100">
                      {entry.body}
                    </div>
                  <% entry.kind == :assistant -> %>
                    <div class="max-w-[96%] whitespace-pre-wrap rounded-lg border border-zinc-700/80 bg-zinc-900/75 px-3 py-1.5 text-[12px] leading-5 text-zinc-100">
                      {entry.body}
                    </div>
                  <% entry.kind == :tool -> %>
                    <div class="max-w-[98%] rounded-md border border-sky-900/70 bg-sky-950/20 px-2.5 py-1.5">
                      <div class="flex items-center justify-between gap-2">
                        <div class="flex min-w-0 items-center gap-1.5">
                          <.icon name="hero-command-line" class="size-3.5 text-sky-300/90" />
                          <p class="truncate text-[11px] leading-4 text-sky-100">{entry.body}</p>
                        </div>
                        <span class={tool_status_chip_class(entry.status)}>
                          {tool_status_text(entry.status)}
                        </span>
                      </div>
                      <pre
                        :if={is_binary(entry.output) and entry.output != ""}
                        class="mt-1.5 max-h-56 overflow-auto whitespace-pre-wrap rounded border border-zinc-800/90 bg-zinc-950/90 px-2 py-1.5 font-mono text-[11px] leading-5 text-zinc-200"
                      >{entry.output}</pre>
                    </div>
                  <% entry.kind == :reasoning -> %>
                    <details class="max-w-[98%] rounded-md border border-zinc-800/80 bg-zinc-900/35 px-2 py-1">
                      <summary class="cursor-pointer select-none text-[10px] uppercase tracking-[0.14em] text-zinc-500 marker:text-zinc-600 hover:text-zinc-300">
                        reasoning
                      </summary>
                      <pre class="mt-1 whitespace-pre-wrap font-mono text-[11px] leading-5 text-zinc-500">{entry.body}</pre>
                    </details>
                  <% entry.kind == :error -> %>
                    <div class="max-w-[98%] whitespace-pre-wrap rounded-md border border-rose-500/45 bg-rose-950/30 px-2.5 py-1.5 text-[11px] leading-5 text-rose-200">
                      {entry.body}
                    </div>
                  <% true -> %>
                    <div class="mx-auto w-fit rounded-md border border-zinc-800 bg-zinc-900/80 px-2 py-0.5 text-[10px] uppercase tracking-[0.1em] text-zinc-500">
                      {entry.body}
                    </div>
                <% end %>
              </div>

              <div id="tool-feed-end"></div>
            </div>
          </main>

          <div id="codex-now-dock" class="border-t border-zinc-800/80 bg-zinc-950/95 backdrop-blur">
            <div class="mx-auto w-full max-w-5xl px-3 py-2 md:px-5">
              <div class="mb-1.5 flex flex-wrap items-center gap-1.5">
                <button
                  id="codex-new-thread"
                  phx-click="new_thread"
                  class="inline-flex min-h-8 items-center rounded-md border border-zinc-600 bg-zinc-900/80 px-2.5 text-[10px] uppercase tracking-[0.08em] text-zinc-100 transition hover:border-zinc-400"
                >
                  New Thread
                </button>
                <button
                  :if={is_binary(@active_turn_id)}
                  id="codex-interrupt"
                  phx-click="interrupt_turn"
                  class="inline-flex min-h-8 items-center rounded-md border border-amber-500/40 bg-amber-500/10 px-2.5 text-[10px] uppercase tracking-[0.08em] text-amber-100 transition hover:bg-amber-500/20"
                >
                  Interrupt
                </button>
              </div>

              <.form
                for={@prompt_form}
                id="codex-prompt-form"
                phx-submit="send_prompt"
                class="flex items-end gap-1.5 pb-[calc(0.35rem+var(--kb,0px))]"
              >
                <.input
                  field={@prompt_form[:prompt]}
                  type="textarea"
                  rows="2"
                  placeholder="Ask Codex..."
                  class="w-full rounded-lg border border-zinc-700 bg-zinc-900/85 px-2.5 py-1.5 font-mono text-[12px] leading-5 text-zinc-100 placeholder:text-zinc-500 focus:border-cyan-500 focus:outline-none"
                />
                <button
                  id="codex-send"
                  type="submit"
                  class="inline-flex min-h-8 items-center rounded-md border border-cyan-500/45 bg-cyan-500/15 px-3 text-[10px] uppercase tracking-[0.08em] text-cyan-100 transition hover:bg-cyan-500/25"
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
    |> assign(:token_usage, Map.get(snapshot, :token_usage) || Map.get(snapshot, "token_usage"))
    |> assign(:rate_limits, Map.get(snapshot, :rate_limits) || Map.get(snapshot, "rate_limits"))
    |> assign(:auth, Map.get(snapshot, :auth) || Map.get(snapshot, "auth"))
    |> assign(:runtime, Map.get(snapshot, :runtime) || Map.get(snapshot, "runtime"))
    |> stream(
      :entries,
      normalize_entries(Map.get(snapshot, :entries) || Map.get(snapshot, "entries")),
      reset: true
    )
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

  defp follow_mode(active_turn_id) when is_binary(active_turn_id), do: "always"
  defp follow_mode(_), do: "smart"

  defp status_text(:booting), do: "booting"
  defp status_text(:ready), do: "ready"
  defp status_text(:error), do: "error"
  defp status_text(_), do: "unknown"

  defp status_chip_class(:ready),
    do:
      "inline-flex items-center rounded-md border border-emerald-700/70 bg-emerald-950/35 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-[0.08em] text-emerald-300"

  defp status_chip_class(:booting),
    do:
      "inline-flex items-center rounded-md border border-cyan-700/70 bg-cyan-950/35 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-[0.08em] text-cyan-300"

  defp status_chip_class(:error),
    do:
      "inline-flex items-center rounded-md border border-rose-700/70 bg-rose-950/35 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-[0.08em] text-rose-300"

  defp status_chip_class(_),
    do:
      "inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/80 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-[0.08em] text-zinc-300"

  defp tool_status_chip_class("running"),
    do:
      "inline-flex items-center rounded-md border border-cyan-800/80 bg-cyan-950/35 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-cyan-300"

  defp tool_status_chip_class("ok"),
    do:
      "inline-flex items-center rounded-md border border-emerald-800/80 bg-emerald-950/35 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-emerald-300"

  defp tool_status_chip_class("error"),
    do:
      "inline-flex items-center rounded-md border border-rose-800/80 bg-rose-950/35 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-rose-300"

  defp tool_status_chip_class(_),
    do:
      "inline-flex items-center rounded-md border border-zinc-800/80 bg-zinc-900/40 px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-[0.12em] text-zinc-300"

  defp tool_status_text("running"), do: "running"
  defp tool_status_text("ok"), do: "done"
  defp tool_status_text("error"), do: "error"
  defp tool_status_text("done"), do: "done"
  defp tool_status_text(_), do: "update"

  defp display_thread(thread_id) when is_binary(thread_id), do: short_id(thread_id)
  defp display_thread(_), do: "none"

  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short_id(value), do: to_string(value)

  defp token_usage_badge(token_usage) when is_map(token_usage) do
    last_total =
      get_in(token_usage, ["last", "totalTokens"]) || get_in(token_usage, [:last, :totalTokens])

    total =
      get_in(token_usage, ["total", "totalTokens"]) || get_in(token_usage, [:total, :totalTokens])

    cond do
      is_integer(last_total) and is_integer(total) ->
        "tokens #{format_int(last_total)} turn · #{format_int(total)} total"

      is_integer(last_total) ->
        "tokens #{format_int(last_total)} turn"

      is_integer(total) ->
        "tokens #{format_int(total)} total"

      true ->
        nil
    end
  end

  defp token_usage_badge(_), do: nil

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

  defp runtime_badges(runtime) when is_map(runtime) do
    model = runtime_field(runtime, :model, "model")
    provider = runtime_field(runtime, :model_provider, "model_provider")
    reasoning = runtime_field(runtime, :reasoning_effort, "reasoning_effort")
    approval = runtime_field(runtime, :approval_policy, "approval_policy")
    sandbox = runtime_field(runtime, :sandbox, "sandbox")
    personality = runtime_field(runtime, :personality, "personality")

    []
    |> maybe_add_badge(model, "model")
    |> maybe_add_badge(provider, "provider")
    |> maybe_add_badge(reasoning, "reasoning")
    |> maybe_add_badge(approval, "approval")
    |> maybe_add_badge(sandbox, "sandbox")
    |> maybe_add_badge(personality, "persona")
  end

  defp runtime_badges(_), do: []

  defp maybe_add_badge(badges, value, label) when is_list(badges) and is_binary(label) do
    if is_binary(value) and value != "" do
      badges ++ ["#{label} #{truncate(value, 36)}"]
    else
      badges
    end
  end

  defp runtime_chip_class(badge) when is_binary(badge) do
    cond do
      String.starts_with?(badge, "model ") ->
        "inline-flex items-center rounded-md border border-sky-800/80 bg-sky-950/35 px-1.5 py-0.5 text-[10px] text-sky-200"

      String.starts_with?(badge, "provider ") ->
        "inline-flex items-center rounded-md border border-indigo-800/80 bg-indigo-950/35 px-1.5 py-0.5 text-[10px] text-indigo-200"

      true ->
        "inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/75 px-1.5 py-0.5 text-[10px] text-zinc-300"
    end
  end

  defp runtime_chip_class(_),
    do:
      "inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/75 px-1.5 py-0.5 text-[10px] text-zinc-300"

  defp runtime_field(runtime, atom_key, string_key) when is_map(runtime) do
    Map.get(runtime, atom_key) || Map.get(runtime, string_key)
  end

  defp runtime_field(_runtime, _atom_key, _string_key), do: nil

  defp auth_badge(auth) when is_map(auth) do
    authenticated = auth_field(auth, :authenticated, "authenticated") == true
    account_type = auth_field(auth, :account_type, "account_type")
    plan_type = auth_field(auth, :plan_type, "plan_type")
    email = auth_field(auth, :email, "email")
    requires_openai_auth = auth_field(auth, :requires_openai_auth, "requires_openai_auth") == true
    probe_error = auth_field(auth, :probe_error, "probe_error")

    cond do
      authenticated ->
        parts =
          [account_type, plan_type, email]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        if parts == [] do
          "auth ok"
        else
          "auth " <> Enum.join(parts, " · ")
        end

      is_binary(probe_error) ->
        "auth probe failed"

      requires_openai_auth ->
        "auth required"

      true ->
        "auth unknown"
    end
  end

  defp auth_badge(_), do: nil

  defp auth_chip_class(auth) when is_map(auth) do
    authenticated = auth_field(auth, :authenticated, "authenticated") == true
    probe_error = auth_field(auth, :probe_error, "probe_error")
    requires_openai_auth = auth_field(auth, :requires_openai_auth, "requires_openai_auth") == true

    cond do
      authenticated ->
        "inline-flex items-center rounded-md border border-emerald-700/70 bg-emerald-950/35 px-1.5 py-0.5 text-[10px] text-emerald-300"

      is_binary(probe_error) ->
        "inline-flex items-center rounded-md border border-rose-700/70 bg-rose-950/35 px-1.5 py-0.5 text-[10px] text-rose-300"

      requires_openai_auth ->
        "inline-flex items-center rounded-md border border-amber-700/70 bg-amber-950/35 px-1.5 py-0.5 text-[10px] text-amber-200"

      true ->
        "inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/75 px-1.5 py-0.5 text-[10px] text-zinc-300"
    end
  end

  defp auth_chip_class(_),
    do:
      "inline-flex items-center rounded-md border border-zinc-700/90 bg-zinc-900/75 px-1.5 py-0.5 text-[10px] text-zinc-300"

  defp auth_field(auth, atom_key, string_key) when is_map(auth) do
    Map.get(auth, atom_key) || Map.get(auth, string_key)
  end

  defp auth_field(_auth, _atom_key, _string_key), do: nil

  defp format_int(int) when is_integer(int) and int >= 0 do
    int
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  defp format_int(int) when is_integer(int), do: Integer.to_string(int)

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
