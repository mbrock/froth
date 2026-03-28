defmodule FrothWeb.CodexLive do
  use FrothWeb, :live_view

  alias Froth.Codex.Events, as: CodexEvents
  alias Froth.Telemetry.Span
  alias Froth.Codex.Session, as: CodexSession

  @default_model "gpt-5.4"
  @reasoning_efforts ~w(low medium high xhigh)

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
    socket =
      allow_upload(socket, :images,
        accept: ~w(.png .jpg .jpeg .webp .gif .avif),
        auto_upload: true,
        max_entries: 6
      )

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
        |> assign(:active_assistant_entry_id, nil)
        |> assign(:now_ms, System.system_time(:millisecond))
        |> assign(:token_usage, nil)
        |> assign(:rate_limits, nil)
        |> assign(:auth, nil)
        |> assign(:runtime, nil)
        |> assign(:available_models, [])
        |> assign(:available_models_refresh_attempted?, false)
        |> assign(:session_stats, empty_session_stats())
        |> assign(:sessions, [])
        |> assign(:model_form, model_form(nil, []))
        |> assign(:reasoning_form, reasoning_form(nil))
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
        |> assign(:active_assistant_entry_id, nil)
        |> assign(:now_ms, System.system_time(:millisecond))
        |> assign(:token_usage, nil)
        |> assign(:rate_limits, nil)
        |> assign(:auth, nil)
        |> assign(:runtime, nil)
        |> assign(:available_models, [])
        |> assign(:available_models_refresh_attempted?, false)
        |> assign(:session_stats, empty_session_stats())
        |> assign(:model_form, model_form(nil, []))
        |> assign(:reasoning_form, reasoning_form(nil))
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

  def handle_event("prompt_changed", %{"codex" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :prompt_form, to_form(params, as: :codex))}
  end

  def handle_event("send_prompt", %{"codex" => %{"prompt" => raw_prompt}}, socket) do
    prompt = String.trim(raw_prompt || "")
    pending_image_count = pending_image_count(socket)

    uploaded_images =
      if pending_image_count == 0 do
        persist_prompt_images(socket)
      else
        []
      end

    socket =
      cond do
        prompt == "" and uploaded_images == [] and pending_image_count == 0 ->
          socket

        pending_image_count > 0 ->
          put_flash(socket, :error, "wait for pasted images to finish uploading")

        true ->
          Span.execute([:froth, :web, :send_prompt], nil, %{
            session_id: socket.assigns.session_id
          })

          case CodexSession.send_prompt(socket.assigns.session_id, prompt,
                 images: uploaded_images
               ) do
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

  def handle_event("cancel_image_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle_event(
        "set_reasoning_effort",
        %{"reasoning" => %{"effort" => raw_effort}},
        %{assigns: %{mode: :session}} = socket
      ) do
    socket = assign(socket, :reasoning_form, reasoning_form(raw_effort))
    effort = normalize_reasoning_effort(raw_effort)

    cond do
      is_nil(effort) ->
        {:noreply, put_flash(socket, :error, "unsupported reasoning effort")}

      current_reasoning_effort(socket.assigns.runtime) == effort ->
        {:noreply, socket}

      true ->
        case CodexSession.set_reasoning_effort(socket.assigns.session_id, effort) do
          :ok ->
            {:noreply, refresh_snapshot(socket)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "reasoning update failed: #{inspect(reason)}")
             |> refresh_snapshot()}
        end
    end
  end

  def handle_event(
        "set_model",
        %{"model" => %{"model" => raw_model}},
        %{assigns: %{mode: :session}} = socket
      ) do
    socket = assign(socket, :model_form, model_form(raw_model, socket.assigns.available_models))
    model = normalize_model_value(raw_model)
    allowed_models = allowed_model_values(socket.assigns.runtime, socket.assigns.available_models)

    cond do
      is_nil(model) ->
        {:noreply, put_flash(socket, :error, "unsupported model")}

      model not in allowed_models ->
        {:noreply, put_flash(socket, :error, "unsupported model")}

      current_model(socket.assigns.runtime, socket.assigns.available_models) == model ->
        {:noreply, socket}

      true ->
        case CodexSession.set_model(socket.assigns.session_id, model) do
          :ok ->
            {:noreply, refresh_snapshot(socket)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "model update failed: #{inspect(reason)}")
             |> refresh_snapshot()}
        end
    end
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

    socket =
      socket
      |> assign(:now_ms, System.system_time(:millisecond))
      |> maybe_refresh_available_models()

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
          phx-hook="CodexTimeline"
          class="mini-shell codex-shell safe-top flex min-h-0 flex-col text-zinc-100"
        >
          <main
            id="tool-feed"
            data-scroll-body
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain"
          >
            <div
              id="codex-feed-list"
              data-codex-feed
              phx-update="stream"
              class="mx-auto flex w-full max-w-[72rem] flex-col gap-2 px-3 py-3"
            >
              <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} data-codex-entry>
                <%= cond do %>
                  <% entry.kind == :user -> %>
                    <.codex_message
                      body={entry.body}
                      images={entry.images}
                      tone={:user}
                      streaming?={false}
                    />
                  <% entry.kind == :assistant -> %>
                    <.codex_message
                      body={entry.body}
                      images={entry.images}
                      tone={:assistant}
                      streaming?={
                        assistant_entry_streaming?(
                          entry,
                          @active_assistant_entry_id,
                          @active_turn_id
                        )
                      }
                    />
                  <% entry.kind == :tool -> %>
                    <.codex_tool_entry entry={entry} />
                  <% entry.kind == :reasoning -> %>
                    <div class="codex-note text-zinc-500">
                      <span class="codex-kicker">reasoning</span>
                      <pre class="mt-1 whitespace-pre-wrap font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[11px] leading-5 text-zinc-500">{entry.body}</pre>
                    </div>
                  <% entry.kind == :error -> %>
                    <div class="codex-note border-l-2 border-rose-400/60 bg-rose-950/20 whitespace-pre-wrap px-2.5 py-2 text-[12px] leading-5 text-rose-100">
                      {entry.body}
                    </div>
                  <% true -> %>
                    <.codex_status_entry entry={entry} />
                <% end %>
              </div>

              <div id="tool-feed-end" data-scroll-end></div>
            </div>
          </main>

          <div id="codex-now-dock" class="safe-bottom">
            <div class="mx-auto w-full max-w-[72rem] px-3 py-2.5">
              <%= if session_working?(@codex_status, @active_turn_id) do %>
                <div
                  id="codex-working-dock"
                  class="flex items-center justify-between gap-2 rounded-[1.35rem] border border-white/10 bg-black/60 px-2 py-2 shadow-[0_10px_35px_rgba(0,0,0,0.28)]"
                >
                  <div class="flex min-w-0 items-center gap-1.5 overflow-x-auto [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden">
                    <span class={session_status_text_class(@codex_status, @active_turn_id)}>
                      {session_status_text(@codex_status, @active_turn_id)}
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
                      class="inline-flex shrink-0 items-center rounded-full border border-white/10 bg-white/[0.04] px-2 py-1 text-[10px] font-medium leading-none text-zinc-400"
                    >
                      {elapsed_badge(
                        @active_turn_id,
                        @active_turn_started_at_ms,
                        @last_turn_elapsed_ms,
                        @now_ms
                      )}
                    </span>
                    <span
                      :if={tool_progress_badge(@session_stats)}
                      class="inline-flex shrink-0 items-center rounded-full border border-white/10 bg-white/[0.04] px-2 py-1 text-[10px] font-medium leading-none text-zinc-400"
                    >
                      {tool_progress_badge(@session_stats)}
                    </span>
                  </div>

                  <div class="flex shrink-0 items-center gap-1.5">
                    <.form
                      for={@reasoning_form}
                      id="codex-reasoning-form"
                      phx-change="set_reasoning_effort"
                      class="inline-flex"
                    >
                      <.input
                        field={@reasoning_form[:effort]}
                        id="codex-reasoning-effort"
                        type="select"
                        variant="bare"
                        options={reasoning_effort_options()}
                        class="h-8 w-[5.25rem] rounded-full border border-white/12 bg-white/[0.05] px-3 pr-8 font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[11px] text-zinc-100 lowercase outline-none transition hover:border-white/22 hover:bg-white/[0.08] focus:border-cyan-400/60 focus:ring-2 focus:ring-cyan-400/25 disabled:cursor-not-allowed disabled:opacity-50"
                        aria-label="Reasoning effort"
                        disabled={@codex_status != :ready}
                      />
                    </.form>

                    <button
                      id="codex-interrupt"
                      phx-click="interrupt_turn"
                      class="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-full border border-amber-300/20 bg-amber-400/10 px-3 text-[10px] font-semibold uppercase tracking-[0.14em] text-amber-100 transition hover:border-amber-300/40 hover:bg-amber-400/18 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-300/40"
                    >
                      <.icon name="hero-stop" class="size-3.5" />
                      <span>Stop</span>
                    </button>
                  </div>
                </div>
              <% else %>
                <div class="pb-[calc(0.2rem+var(--kb,0px))]">
                  <div
                    :if={@uploads.images.entries != []}
                    id="codex-image-staging"
                    class="mb-1.5 flex flex-wrap gap-1.5"
                  >
                    <div
                      :for={entry <- @uploads.images.entries}
                      class="group relative h-14 w-14 shrink-0 overflow-hidden bg-black/55 ring-1 ring-white/8"
                    >
                      <.live_img_preview entry={entry} class="h-full w-full object-cover" />
                      <button
                        type="button"
                        phx-click="cancel_image_upload"
                        phx-value-ref={entry.ref}
                        class="absolute right-0 top-0 px-1.5 py-1 text-[10px] leading-none text-zinc-300 transition hover:text-white"
                        aria-label="Remove image"
                      >
                        ×
                      </button>
                    </div>
                  </div>

                  <div class="rounded-[1.35rem] border border-white/10 bg-black/55 px-2 py-2 shadow-[0_10px_35px_rgba(0,0,0,0.28)] transition focus-within:border-cyan-400/45 focus-within:bg-black/70">
                    <div class="mb-1.5 flex items-center justify-between gap-2">
                      <div class="flex items-center gap-1.5">
                        <label
                          for="codex-image-upload"
                          id="codex-upload-image"
                          class="inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-full border border-white/10 bg-white/[0.05] text-zinc-300 transition hover:border-cyan-300/40 hover:bg-cyan-400/12 hover:text-cyan-50 focus-within:ring-2 focus-within:ring-cyan-400/40"
                          aria-label="Upload image"
                          title="Upload image"
                        >
                          <.icon name="hero-photo" class="size-4" />
                        </label>

                        <button
                          id="codex-new-thread"
                          phx-click="new_thread"
                          class="inline-flex size-8 items-center justify-center rounded-full border border-white/10 bg-white/[0.05] text-zinc-300 transition hover:border-white/20 hover:bg-white/[0.1] hover:text-zinc-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-400/45"
                          aria-label="New thread"
                          title="New thread"
                        >
                          <.icon name="hero-plus" class="size-4" />
                        </button>
                      </div>

                      <div class="flex items-center gap-1.5">
                        <.form
                          for={@reasoning_form}
                          id="codex-reasoning-form"
                          phx-change="set_reasoning_effort"
                          class="inline-flex"
                        >
                          <.input
                            field={@reasoning_form[:effort]}
                            id="codex-reasoning-effort"
                            type="select"
                            variant="bare"
                            options={reasoning_effort_options()}
                            class="h-8 w-[5.25rem] rounded-full border border-white/12 bg-white/[0.05] px-3 pr-8 font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[11px] text-zinc-100 lowercase outline-none transition hover:border-white/22 hover:bg-white/[0.08] focus:border-cyan-400/60 focus:ring-2 focus:ring-cyan-400/25 disabled:cursor-not-allowed disabled:opacity-50"
                            aria-label="Reasoning effort"
                            disabled={@codex_status != :ready}
                          />
                        </.form>

                        <button
                          id="codex-send"
                          type="submit"
                          form="codex-prompt-form"
                          class="inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-cyan-400/90 text-slate-950 shadow-[0_8px_24px_rgba(34,211,238,0.28)] transition hover:bg-cyan-300 hover:shadow-[0_10px_30px_rgba(34,211,238,0.38)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-200/70"
                          aria-label="Send"
                          title="Send"
                        >
                          <.icon name="hero-arrow-up" class="size-4" />
                        </button>
                      </div>
                    </div>

                    <.form
                      for={@prompt_form}
                      id="codex-prompt-form"
                      phx-change="prompt_changed"
                      phx-submit="send_prompt"
                    >
                      <.input
                        field={@prompt_form[:prompt]}
                        id="codex-prompt"
                        type="textarea"
                        variant="bare"
                        rows="1"
                        placeholder="Message Codex"
                        enterkeyhint="send"
                        phx-hook="CodexComposer"
                        data-upload-input-id="codex-image-upload"
                        class="min-h-[2.9rem] max-h-40 w-full resize-none border-0 bg-transparent px-0 py-1.5 text-[15px] leading-6 text-zinc-50 outline-none placeholder:text-zinc-500 focus:ring-0"
                      />

                      <.live_file_input
                        upload={@uploads.images}
                        id="codex-image-upload"
                        class="sr-only"
                      />
                    </.form>
                  </div>
                </div>
              <% end %>
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
  attr :images, :list, default: []
  attr :tone, :atom, required: true
  attr :streaming?, :boolean, default: false

  defp codex_message(assigns) do
    {text, footer} = split_cost_footer(assigns.body)

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:footer, footer)
      |> assign(:image_urls, entry_image_urls(assigns.images))
      |> assign(:html, message_body_html(text, assigns.streaming?))

    ~H"""
    <div :if={@text || @footer || @image_urls != [] || @streaming?} class={codex_message_class(@tone)}>
      <div :if={@image_urls != []} class="mb-3 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
        <div :for={image <- @image_urls} class="overflow-hidden border border-white/10 bg-black/40">
          <img src={image.url} alt={image.alt} class="h-auto w-full object-cover" loading="lazy" />
        </div>
      </div>
      <div :if={@text || @streaming?} class={codex_message_text_class(@tone)}>
        {raw(@html)}
      </div>
      <div :if={@footer} class="mt-2">
        <.metadata_footer footer={@footer} />
      </div>
    </div>
    """
  end

  attr :footer, :string, required: true

  defp metadata_footer(assigns) do
    ~H"""
    <div class="mt-1 text-[10px] text-zinc-500">
      {@footer}
    </div>
    """
  end

  defp message_body_html(text, streaming?) do
    html = render_markdown_html(text || "")

    if streaming? do
      append_streaming_tail(html)
    else
      html
    end
  end

  defp append_streaming_tail(html) when is_binary(html) do
    tail = streaming_tail_html()
    trimmed = String.trim_trailing(html)

    cond do
      trimmed == "" ->
        tail

      true ->
        updated =
          Regex.replace(
            ~r{</(p|li|blockquote|h[1-6])>\s*\z}i,
            trimmed,
            " " <> tail <> "</\\1>"
          )

        if updated == trimmed, do: trimmed <> tail, else: updated
    end
  end

  defp append_streaming_tail(_), do: streaming_tail_html()

  defp streaming_tail_html do
    """
    <span class="codex-inline-spinner" aria-hidden="true">
      <span></span><span></span><span></span>
    </span>
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
      <div class="flex items-center justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <span class="codex-kicker text-sky-300/80">tool call</span>
            <div
              :if={@entry.status == "running"}
              class="inline-flex items-center gap-1 font-[JetBrains_Mono,ui-monospace,SFMono-Regular,Menlo,Monaco,monospace] text-[10px] text-amber-200/85"
            >
              <span>live</span>
              <.working_dots />
            </div>
          </div>
        </div>
        <span class={tool_status_text_class(@entry.status)}>
          {tool_status_text(@entry.status)}
        </span>
      </div>

      <div class="mt-1.5">
        <div class="codex-kicker text-zinc-500">command</div>
        <pre class="codex-pre codex-pre--command">{@entry.body}</pre>
      </div>

      <div :if={is_binary(@entry.output) and @entry.output != ""} class="mt-1.5">
        <div class="codex-kicker text-zinc-500">output</div>
        <pre class="codex-pre codex-pre--output">{@entry.output}</pre>
      </div>
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
      <div class="flex flex-wrap items-center gap-2">
        <span class={status_entry_kicker_class(@descriptor.tone)}>{@descriptor.badge}</span>
        <p class="font-[IBM_Plex_Sans,ui-sans-serif,system-ui,sans-serif] text-[12px] leading-5 text-zinc-100">
          {@descriptor.title}
        </p>
        <.working_dots :if={@descriptor.spinner?} class="text-amber-200/85" />
      </div>

      <p
        :if={@descriptor.subtitle}
        class="mt-1 font-[IBM_Plex_Sans,ui-sans-serif,system-ui,sans-serif] text-[12px] leading-5 text-zinc-400"
      >
        {@descriptor.subtitle}
      </p>

      <div :if={@descriptor.plan_steps != []} class="mt-1.5 space-y-1">
        <div
          :for={step <- @descriptor.plan_steps}
          class="flex items-start gap-2 text-[12px] leading-5"
        >
          <span class={plan_step_status_class(step.status)}>
            {plan_step_status_text(step.status)}
          </span>
          <p class="min-w-0 flex-1 text-[12px] leading-5 text-zinc-200">{step.step}</p>
        </div>
      </div>
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
      socket
      |> apply_snapshot(snapshot)
      |> maybe_refresh_available_models()
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

  defp maybe_refresh_available_models(
         %{
           assigns: %{
             mode: :session,
             codex_status: :ready,
             available_models: [],
             available_models_refresh_attempted?: false
           }
         } = socket
       ) do
    socket = assign(socket, :available_models_refresh_attempted?, true)

    case CodexSession.refresh_available_models(socket.assigns.session_id) do
      :ok ->
        refresh_snapshot(socket)

      {:error, reason} ->
        Span.execute([:froth, :web, :model_refresh_failed], nil, %{
          session_id: socket.assigns.session_id,
          reason: inspect(reason)
        })

        socket
    end
  end

  defp maybe_refresh_available_models(socket), do: socket

  defp apply_snapshot(socket, snapshot) when is_map(snapshot) do
    runtime = Map.get(snapshot, :runtime) || Map.get(snapshot, "runtime")

    available_models =
      Map.get(snapshot, :available_models) || Map.get(snapshot, "available_models") || []

    available_models_checked? =
      Map.get(snapshot, :available_models_checked?) ||
        Map.get(snapshot, "available_models_checked?") ||
        available_models != [] ||
        socket.assigns.available_models_refresh_attempted?

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
    |> assign(
      :active_assistant_entry_id,
      normalize_optional_text(
        Map.get(snapshot, :active_assistant_entry_id) ||
          Map.get(snapshot, "active_assistant_entry_id")
      )
    )
    |> assign(:token_usage, Map.get(snapshot, :token_usage) || Map.get(snapshot, "token_usage"))
    |> assign(:rate_limits, Map.get(snapshot, :rate_limits) || Map.get(snapshot, "rate_limits"))
    |> assign(:auth, Map.get(snapshot, :auth) || Map.get(snapshot, "auth"))
    |> assign(:runtime, runtime)
    |> assign(:available_models, available_models)
    |> assign(:available_models_refresh_attempted?, available_models_checked?)
    |> assign(:model_form, model_form(runtime, available_models))
    |> assign(:reasoning_form, reasoning_form(runtime))
    |> assign(:session_stats, build_session_stats(entries))
    |> stream(:entries, entries, reset: true)
  end

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(&normalize_entry/1)
    |> Enum.reject(&hidden_entry?/1)
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
      images: normalize_entry_images(Map.get(entry, :images) || Map.get(entry, "images")),
      label: normalize_optional_text(label),
      sequence: normalize_optional_sequence(sequence)
    }
  end

  defp normalize_entry(other),
    do: %{id: "entry-#{:erlang.phash2(other)}", kind: :event, body: inspect(other)}

  defp hidden_entry?(%{kind: :status, body: body}) when is_binary(body),
    do: String.starts_with?(String.trim_leading(body), "working")

  defp hidden_entry?(_), do: false

  defp normalize_entry_kind(kind)
       when kind in [:assistant, :error, :event, :reasoning, :status, :system, :tool, :user],
       do: kind

  defp normalize_entry_kind(kind) when is_binary(kind),
    do: Map.get(@entry_kinds, kind, :event)

  defp normalize_entry_kind(_), do: :event

  defp normalize_optional_text(nil), do: nil
  defp normalize_optional_text(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_text(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_text(_), do: nil

  defp normalize_entry_images(images) when is_list(images) do
    Enum.flat_map(images, fn
      %{url: url} = image when is_binary(url) and url != "" ->
        [%{url: url, alt: Map.get(image, :alt) || "Attached image"}]

      %{"url" => url} = image when is_binary(url) and url != "" ->
        [%{url: url, alt: image["alt"] || "Attached image"}]

      url when is_binary(url) and url != "" ->
        [%{url: url, alt: "Attached image"}]

      _ ->
        []
    end)
  end

  defp normalize_entry_images(_), do: []

  defp normalize_optional_sequence(value) when is_integer(value), do: value

  defp normalize_optional_sequence(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_sequence(_), do: nil

  defp assistant_entry_streaming?(entry, active_assistant_entry_id, active_turn_id)
       when is_map(entry) and is_binary(active_assistant_entry_id) and is_binary(active_turn_id) do
    entry.id == active_assistant_entry_id
  end

  defp assistant_entry_streaming?(_entry, _active_assistant_entry_id, _active_turn_id), do: false

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
    do: "codex-note border-l border-zinc-700/65 bg-zinc-950/68 px-2.5 py-2"

  defp codex_message_class(:user),
    do: "codex-note border-l border-emerald-400/45 bg-emerald-500/[0.06] px-2.5 py-2"

  defp codex_message_class(_),
    do: "codex-note border-l border-zinc-700/65 bg-zinc-950/68 px-2.5 py-2"

  defp codex_message_text_class(:assistant),
    do:
      "mini-markdown md-prose font-[IBM_Plex_Sans,ui-sans-serif,system-ui,sans-serif] text-[14px] leading-[1.56] text-zinc-100"

  defp codex_message_text_class(:user),
    do:
      "mini-markdown md-prose font-[IBM_Plex_Sans,ui-sans-serif,system-ui,sans-serif] text-[14px] leading-[1.56] text-emerald-50"

  defp codex_message_text_class(_),
    do:
      "mini-markdown md-prose font-[IBM_Plex_Sans,ui-sans-serif,system-ui,sans-serif] text-[14px] leading-[1.56] text-zinc-100"

  defp codex_tool_card_class("error"),
    do: "codex-note border-l border-rose-400/55 bg-rose-950/18 px-2.5 py-2"

  defp codex_tool_card_class("running"),
    do: "codex-note border-l border-amber-400/55 bg-amber-950/14 px-2.5 py-2"

  defp codex_tool_card_class(_),
    do: "codex-note border-l border-sky-400/45 bg-sky-950/14 px-2.5 py-2"

  defp status_entry_descriptor(entry) when is_map(entry) do
    body = blank_to_nil(entry.body) || "update"
    details = blank_to_nil(entry.output)
    subtitle = blank_to_nil(entry.label)

    cond do
      received = parse_received_status(body, details, subtitle) ->
        received

      String.starts_with?(body, "working") ->
        %{
          badge: "turn",
          tone: :warning,
          title: "Working",
          subtitle: nil,
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

      body == "thread started" or String.starts_with?(body, "thread started ") ->
        %{
          badge: "thread",
          tone: :success,
          title: "Thread started",
          subtitle: nil,
          details: details,
          plan_steps: [],
          spinner?: false
        }

      body == "thread ready" or String.starts_with?(body, "thread ready ") ->
        %{
          badge: "thread",
          tone: :success,
          title: "Thread ready",
          subtitle: nil,
          details: details,
          plan_steps: [],
          spinner?: false
        }

      String.starts_with?(body, "resumed thread ") or String.starts_with?(body, "thread resumed") ->
        %{
          badge: "thread",
          tone: :success,
          title: "Thread resumed",
          subtitle: nil,
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

  defp parse_received_status(body, _details, subtitle) when is_binary(body) do
    case Regex.run(~r/^received\s+([^\s]+)\s*(.*)$/s, body, capture: :all_but_first) do
      [method, raw] ->
        plan_steps = protocol_plan_steps(raw)

        %{
          badge: if(String.contains?(method, "plan"), do: "plan", else: "event"),
          tone: protocol_tone(method, plan_steps),
          title: protocol_title(method),
          subtitle: protocol_summary(method, raw) || subtitle,
          details: nil,
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
    do: "codex-note border-l border-amber-400/40 bg-amber-950/10 px-2.5 py-1.5"

  defp status_entry_class(:success),
    do: "codex-note border-l border-emerald-400/40 bg-emerald-950/10 px-2.5 py-1.5"

  defp status_entry_class(:error),
    do: "codex-note border-l border-rose-400/40 bg-rose-950/10 px-2.5 py-1.5"

  defp status_entry_class(_),
    do: "codex-note border-l border-zinc-700/55 bg-zinc-950/60 px-2.5 py-1.5"

  defp status_entry_kicker_class(:warning), do: "codex-kicker text-amber-300/80"

  defp status_entry_kicker_class(:success), do: "codex-kicker text-emerald-300/80"

  defp status_entry_kicker_class(:error), do: "codex-kicker text-rose-300/80"

  defp status_entry_kicker_class(_), do: "codex-kicker text-zinc-500"

  defp plan_step_status_class("completed"),
    do: "shrink-0 text-[10px] uppercase tracking-[0.14em] text-emerald-300/80"

  defp plan_step_status_class("in_progress"),
    do: "shrink-0 text-[10px] uppercase tracking-[0.14em] text-amber-300/80"

  defp plan_step_status_class("pending"),
    do: "shrink-0 text-[10px] uppercase tracking-[0.14em] text-zinc-500"

  defp plan_step_status_class(_),
    do: "shrink-0 text-[10px] uppercase tracking-[0.14em] text-sky-300/80"

  defp plan_step_status_text("completed"), do: "done"
  defp plan_step_status_text("in_progress"), do: "active"
  defp plan_step_status_text("pending"), do: "queued"
  defp plan_step_status_text(status) when is_binary(status), do: status
  defp plan_step_status_text(_), do: "step"

  defp tool_status_text_class("running"), do: "codex-kicker text-amber-300/80"

  defp tool_status_text_class("ok"), do: "codex-kicker text-emerald-300/80"

  defp tool_status_text_class("error"), do: "codex-kicker text-rose-300/80"

  defp tool_status_text_class(_), do: "codex-kicker text-zinc-500"

  defp tool_status_text("running"), do: "running"
  defp tool_status_text("ok"), do: "done"
  defp tool_status_text("error"), do: "error"
  defp tool_status_text("done"), do: "done"
  defp tool_status_text(_), do: "update"

  defp modeline_model(runtime) when is_map(runtime), do: runtime_field(runtime, :model, "model")
  defp modeline_model(_), do: nil

  defp model_field(model, atom_key, string_key) when is_map(model) do
    Map.get(model, atom_key) || Map.get(model, string_key)
  end

  defp model_field(_model, _atom_key, _string_key), do: nil

  defp model_options(models, current_model) do
    choices =
      models
      |> List.wrap()
      |> Enum.map(&normalize_model_choice/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(fn choice -> choice.hidden? and choice.value != current_model end)
      |> Enum.uniq_by(& &1.value)

    choices =
      if is_binary(current_model) and current_model != "" and
           Enum.any?(choices, &(&1.value == current_model)) do
        choices
      else
        [%{label: current_model_label(current_model), value: current_model} | choices]
      end

    Enum.map(choices, &{&1.label, &1.value})
  end

  defp normalize_model_choice(model) when is_map(model) do
    value = model_choice_value(model)

    if is_binary(value) and value != "" do
      %{
        label: model_choice_label(model, value),
        value: value,
        hidden?: model_choice_hidden?(model)
      }
    end
  end

  defp normalize_model_choice(_), do: nil

  defp model_choice_value(model) when is_map(model) do
    model_field(model, :id, "id") ||
      model_field(model, :model, "model")
  end

  defp model_choice_value(_), do: nil

  defp model_choice_label(model, value) when is_map(model) and is_binary(value) do
    model_field(model, :displayName, "displayName") ||
      model_field(model, :display_name, "display_name") ||
      value
  end

  defp model_choice_label(_model, value), do: value

  defp model_choice_default?(model) when is_map(model) do
    model_flag?(model, :isDefault, "isDefault") || model_flag?(model, :is_default, "is_default")
  end

  defp model_choice_default?(_), do: false

  defp model_choice_hidden?(model) when is_map(model) do
    model_flag?(model, :hidden, "hidden")
  end

  defp model_choice_hidden?(_), do: false

  defp model_flag?(model, atom_key, string_key) when is_map(model) do
    Map.get(model, atom_key) == true || Map.get(model, string_key) == true
  end

  defp model_flag?(_model, _atom_key, _string_key), do: false

  defp current_model(runtime, available_models) when is_map(runtime) do
    case modeline_model(runtime) do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        default_model(available_models)
    end
  end

  defp current_model(model, available_models) when is_binary(model) do
    normalize_model_value(model) || default_model(available_models)
  end

  defp current_model(_runtime, available_models), do: default_model(available_models)

  defp default_model(available_models) do
    case Enum.find(List.wrap(available_models), &model_choice_default?/1) do
      nil -> @default_model
      model -> model_choice_value(model) || @default_model
    end
  end

  defp allowed_model_values(runtime, available_models) do
    model_options(available_models, current_model(runtime, available_models))
    |> Enum.map(&elem(&1, 1))
  end

  defp model_form(runtime_or_model, available_models) do
    to_form(%{"model" => current_model(runtime_or_model, available_models)}, as: :model)
  end

  defp current_model_label(current_model) when is_binary(current_model), do: current_model

  defp current_model_label(_), do: @default_model

  defp normalize_model_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed
  end

  defp normalize_model_value(_), do: nil

  defp modeline_reasoning(runtime) when is_map(runtime),
    do: runtime_field(runtime, :reasoning_effort, "reasoning_effort")

  defp modeline_reasoning(_), do: nil

  defp reasoning_effort_options do
    [
      {"low", "low"},
      {"med", "medium"},
      {"high", "high"},
      {"max", "xhigh"}
    ]
  end

  defp reasoning_form(runtime_or_effort) do
    to_form(%{"effort" => current_reasoning_effort(runtime_or_effort)}, as: :reasoning)
  end

  defp current_reasoning_effort(runtime) when is_map(runtime) do
    case modeline_reasoning(runtime) do
      effort when effort in @reasoning_efforts -> effort
      _ -> "medium"
    end
  end

  defp current_reasoning_effort(effort) when is_binary(effort) do
    normalized = normalize_reasoning_effort(effort)
    normalized || "medium"
  end

  defp current_reasoning_effort(_), do: "medium"

  defp normalize_reasoning_effort(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed in @reasoning_efforts, do: trimmed
  end

  defp normalize_reasoning_effort(_), do: nil

  defp session_status_text(status, active_turn_id) do
    cond do
      is_binary(active_turn_id) -> "working"
      status == :working -> "working"
      status == :ready -> "ready"
      status == :error -> "error"
      status == :booting -> "connecting"
      true -> "idle"
    end
  end

  defp session_working?(status, active_turn_id) do
    is_binary(active_turn_id) or status == :working
  end

  defp session_status_text_class(status, active_turn_id) do
    base =
      "inline-flex shrink-0 items-center rounded-full border px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.16em] leading-none"

    cond do
      is_binary(active_turn_id) or status == :working ->
        base <> " border-amber-300/20 bg-amber-400/10 text-amber-100"

      status == :ready ->
        base <> " border-emerald-300/20 bg-emerald-400/10 text-emerald-100"

      status == :error ->
        base <> " border-rose-300/20 bg-rose-400/10 text-rose-100"

      true ->
        base <> " border-white/10 bg-white/[0.04] text-zinc-400"
    end
  end

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

  defp entry_image_urls(images) when is_list(images) do
    Enum.flat_map(images, fn
      %{url: url} = image when is_binary(url) and url != "" ->
        [%{url: url, alt: Map.get(image, :alt) || "Attached image"}]

      %{"url" => url} = image when is_binary(url) and url != "" ->
        [%{url: url, alt: image["alt"] || "Attached image"}]

      _ ->
        []
    end)
  end

  defp entry_image_urls(_), do: []

  defp attachment_count_label(1), do: "1 image"

  defp attachment_count_label(count) when is_integer(count) and count > 1,
    do: "#{count} images"

  defp attachment_count_label(_), do: nil

  defp pending_image_count(socket) do
    case uploaded_entries(socket, :images) do
      {_done, in_progress} -> length(in_progress)
      _ -> 0
    end
  end

  defp persist_prompt_images(socket) do
    consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
      dest =
        codex_upload_destination(socket.assigns.session_id, entry.client_name, entry.client_type)

      File.mkdir_p!(Path.dirname(dest.path))
      File.cp!(path, dest.path)

      {:ok,
       %{
         path: dest.path,
         url: dest.url,
         alt: image_alt_text(entry.client_name)
       }}
    end)
  end

  defp codex_upload_destination(session_id, client_name, client_type) do
    filename = unique_upload_filename(client_name, client_type)
    relative_path = Path.join([session_id, filename])
    absolute_path = Path.join([File.cwd!(), "priv", "static", "codex_uploads", relative_path])

    %{
      path: absolute_path,
      url: Path.join("/froth/codex_uploads", relative_path)
    }
  end

  defp unique_upload_filename(client_name, client_type) do
    ext =
      client_name
      |> Path.extname()
      |> case do
        "" -> extension_for_type(client_type)
        value -> value
      end

    token = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    "#{System.system_time(:millisecond)}-#{token}#{ext}"
  end

  defp extension_for_type("image/png"), do: ".png"
  defp extension_for_type("image/webp"), do: ".webp"
  defp extension_for_type("image/gif"), do: ".gif"
  defp extension_for_type("image/avif"), do: ".avif"
  defp extension_for_type(_), do: ".jpg"

  defp image_alt_text(nil), do: "Pasted image"

  defp image_alt_text(name) when is_binary(name) do
    case Path.rootname(name) do
      "" -> "Pasted image"
      root -> root
    end
  end

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
        last_body: session.last_body,
        last_metadata: session.last_metadata || %{}
      }
    end)
  end

  defp session_preview_text(session) when is_map(session) do
    kind = session[:last_kind] || session["last_kind"] || "event"
    metadata = session[:last_metadata] || session["last_metadata"] || %{}

    body =
      blank_to_nil(session[:last_body] || session["last_body"]) ||
        image_preview_fallback(metadata) ||
        "no details yet"

    truncate("#{kind}: #{body}", 240)
  end

  defp image_preview_fallback(%{"images" => images}) when is_list(images),
    do: attachment_count_label(length(images))

  defp image_preview_fallback(%{images: images}) when is_list(images),
    do: attachment_count_label(length(images))

  defp image_preview_fallback(_), do: nil

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
