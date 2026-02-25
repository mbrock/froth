defmodule FrothWeb.VoiceLive do
  use FrothWeb, :live_view

  require Logger

  alias Froth.{Qwen, Repo}
  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, Message, Worker}

  @voice_system """
  You are a voice assistant. Keep responses concise and conversational — \
  one to three sentences is ideal. Speak naturally as if talking to someone. \
  Do not use bullet points, numbered lists, markdown formatting, or emoji.\
  """

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        mic = Repo.insert!(%Voice.Stream{rate: 48_000})
        speaker = Repo.insert!(%Voice.Stream{rate: 24_000})

        asr_topic = "asr:#{mic.id}"
        tts_topic = "tts:#{speaker.id}"

        socket
        |> assign(
          mic: mic,
          speaker: speaker,
          tts: nil,
          asr_topic: asr_topic,
          tts_topic: tts_topic
        )
      else
        socket
        |> assign(mic: nil, speaker: nil, tts: nil, asr_topic: nil, tts_topic: nil)
      end

    socket =
      socket
      |> assign(
        page_title: "Voice",
        mic_active: false,
        partial: "",
        client_error: nil,
        pending_user_turns: [],
        transcript_counter: 0,
        cycle: nil,
        head_id: nil,
        worker_pid: nil,
        claude_response: "",
        responding: false
      )
      |> stream(:transcripts, [])

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="min-h-dvh bg-zinc-950 text-zinc-100 flex flex-col">
        <header class="shrink-0 px-4 py-3 border-b border-zinc-800/60 flex items-center gap-3">
          <div class={[
            "w-2 h-2 rounded-full",
            if(@mic_active, do: "bg-red-500 animate-pulse", else: "bg-emerald-500")
          ]}>
          </div>
          <h1 class="text-base font-semibold tracking-tight">Voice</h1>
          <span :if={@responding} class="text-xs text-blue-400 animate-pulse">thinking...</span>
        </header>

        <div class="flex-1 flex flex-col max-w-2xl mx-auto w-full">
          <div class="flex-1 overflow-y-auto p-4" id="transcript-scroll">
            <div id="transcripts" phx-update="stream" class="space-y-2">
              <p
                id="transcripts-empty"
                class="hidden only:block text-sm text-zinc-600 text-center py-12"
              >
                Start speaking to begin
              </p>
              <div
                :for={{id, t} <- @streams.transcripts}
                id={id}
                class={[
                  "text-sm px-3 py-2 rounded-lg max-w-[85%]",
                  if(t.type == :assistant,
                    do: "ml-auto bg-emerald-900/30 text-emerald-100 border border-emerald-800/20",
                    else: "bg-zinc-800/80 text-zinc-300"
                  )
                ]}
              >
                {t.text}
              </div>
            </div>

            <div :if={@responding and @claude_response != ""} class="mt-2 ml-auto max-w-[85%]">
              <div class="text-sm bg-emerald-900/30 text-emerald-100 border border-emerald-800/20 px-3 py-2 rounded-lg">
                {@claude_response}<span class="inline-block w-1.5 h-3.5 bg-emerald-400/70 animate-pulse ml-0.5 align-text-bottom"></span>
              </div>
            </div>
          </div>

          <div
            :if={@partial != ""}
            class="px-4 pb-2 text-sm text-zinc-500 italic truncate"
          >
            {@partial}
          </div>

          <div class="shrink-0 border-t border-zinc-800/60 p-4 space-y-3">
            <div class="flex items-center gap-3">
              <button
                id="mic-btn"
                phx-click="toggle_mic"
                class={[
                  "w-12 h-12 rounded-full flex items-center justify-center transition-all duration-200 shrink-0 cursor-pointer",
                  if(@mic_active,
                    do: "bg-red-600 hover:bg-red-500 shadow-lg shadow-red-900/30",
                    else: "bg-zinc-800 hover:bg-zinc-700 border border-zinc-700"
                  )
                ]}
              >
                <.icon
                  name={if(@mic_active, do: "hero-stop-solid", else: "hero-microphone")}
                  class="w-5 h-5 text-white"
                />
              </button>
            </div>

            <p :if={@mic_active} class="text-xs text-red-400 text-center animate-pulse">
              Listening...
            </p>

            <p :if={@client_error} id="voice-error" class="text-xs text-amber-400 text-center">
              {@client_error}
            </p>
          </div>
        </div>

        <div
          id="debug-log"
          phx-update="ignore"
          class="shrink-0 border-t border-zinc-800/60 bg-black/40 max-h-36 overflow-y-auto font-mono text-[10px] leading-snug text-zinc-500 px-3 py-2 space-y-px"
        >
          <p class="text-zinc-600">debug log</p>
        </div>

        <div
          :if={@mic && @speaker}
          id="voice-audio"
          phx-hook="VoiceAudio"
          phx-update="ignore"
          data-mic-id={@mic.id}
          data-speaker-id={@speaker.id}
          class="hidden"
        >
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- Events ------------------------------------------------------------------

  @impl true
  def handle_event("toggle_mic", _params, socket) do
    if socket.assigns.mic_active do
      Phoenix.PubSub.unsubscribe(Froth.PubSub, socket.assigns.asr_topic)

      {:noreply,
       socket
       |> assign(
         mic_active: false,
         partial: "",
         client_error: nil,
         asr_restart_attempts: 0,
         pending_user_turns: []
       )
       |> push_event("stop_mic", %{})}
    else
      :ok = Phoenix.PubSub.subscribe(Froth.PubSub, socket.assigns.asr_topic)

      {:noreply,
       socket
       |> assign(
         mic_active: true,
         partial: "",
         client_error: nil,
         asr_restart_attempts: 0,
         pending_user_turns: []
       )
       |> push_event("start_mic", %{})}
    end
  end

  def handle_event("client_error", %{"message" => message}, socket) when is_binary(message) do
    {:noreply, assign(socket, client_error: message)}
  end

  # -- Info: ASR events (via PubSub) -------------------------------------------

  @impl true
  def handle_info({:asr_text, %{text: text, stash: stash}}, socket) do
    {:noreply, assign(socket, partial: String.trim("#{text} #{stash}"), client_error: nil)}
  end

  def handle_info({:asr_completed, %{transcript: transcript}}, socket) do
    transcript = String.trim(transcript || "")

    if transcript == "" do
      {:noreply, assign(socket, partial: "")}
    else
      {counter, socket} = next_counter(socket)
      item = %{id: "t-#{counter}", text: transcript, type: :asr}

      socket =
        socket
        |> assign(partial: "", client_error: nil)
        |> stream_insert(:transcripts, item)
        |> push_event("scroll_down", %{})

      socket =
        if socket.assigns.responding do
          update(socket, :pending_user_turns, fn turns -> turns ++ [transcript] end)
        else
          start_agent_turn(socket, transcript)
        end

      {:noreply, socket}
    end
  end

  def handle_info({:asr_speech_started, _ms}, socket) do
    if socket.assigns.responding && socket.assigns.tts do
      Qwen.send_event(socket.assigns.tts, %{type: "session.finish"})
    end

    {:noreply, socket}
  end

  def handle_info({:asr_speech_stopped, _ms}, socket), do: {:noreply, socket}

  # -- Info: TTS events (via PubSub) ------------------------------------------

  def handle_info({:tts_audio, _pcm}, socket), do: {:noreply, socket}
  def handle_info(:tts_response_done, socket), do: {:noreply, socket}

  # -- Info: Agent stream events -----------------------------------------------

  def handle_info({:stream, {:text_delta, delta}}, socket) do
    if socket.assigns.tts,
      do: Qwen.send_event(socket.assigns.tts, %{type: "input_text_buffer.append", text: delta})

    {:noreply, assign(socket, claude_response: socket.assigns.claude_response <> delta)}
  end

  def handle_info({:stream, _event}, socket), do: {:noreply, socket}

  # -- Info: Agent persisted messages ------------------------------------------

  def handle_info({:event, _event, %Message{role: :agent} = msg}, socket) do
    if socket.assigns.tts,
      do: Qwen.send_event(socket.assigns.tts, %{type: "input_text_buffer.commit"})

    response_text = socket.assigns.claude_response
    {counter, socket} = next_counter(socket)
    item = %{id: "t-#{counter}", text: response_text, type: :assistant}

    socket =
      socket
      |> assign(
        claude_response: "",
        head_id: msg.id
      )
      |> stream_insert(:transcripts, item)
      |> push_event("scroll_down", %{})

    case socket.assigns.pending_user_turns do
      [next_user_turn | rest] ->
        socket =
          socket
          |> assign(responding: false, pending_user_turns: rest)
          |> start_agent_turn(next_user_turn)

        {:noreply, socket}

      [] ->
        {:noreply, assign(socket, responding: false)}
    end
  end

  def handle_info({:event, _event, %Message{}}, socket), do: {:noreply, socket}

  # -- Info: WebSocket lifecycle (via PubSub) ----------------------------------

  def handle_info(:qwen_ws_finished, socket), do: {:noreply, socket}

  # -- Info: Process DOWN ------------------------------------------------------

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns.worker_pid do
      {:noreply, assign(socket, worker_pid: nil, responding: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Helpers -----------------------------------------------------------------

  defp ensure_cycle(socket) do
    if socket.assigns.cycle do
      socket
    else
      cycle = Repo.insert!(%Cycle{})
      Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle.id}")
      assign(socket, cycle: cycle)
    end
  end

  defp start_agent_turn(socket, user_text) do
    socket = ensure_cycle(socket)
    cycle = socket.assigns.cycle

    {_msg, head_id} = Agent.append_message(cycle, socket.assigns.head_id, :user, user_text)

    config = %Config{
      system: @voice_system,
      model: "claude-sonnet-4-6",
      thinking: %{"type" => "adaptive"},
      effort: "low",
      tools: []
    }

    if socket.assigns.tts, do: Qwen.send_event(socket.assigns.tts, %{type: "session.finish"})

    Phoenix.PubSub.subscribe(Froth.PubSub, socket.assigns.tts_topic)

    {:ok, tts} =
      Qwen.start_link(
        topic: socket.assigns.tts_topic,
        model: "qwen3-tts-flash-realtime",
        output_stream: socket.assigns.speaker,
        session: %{
          mode: "server_commit",
          voice: "Cherry",
          response_format: "pcm",
          sample_rate: 24_000,
          language_type: "Auto"
        }
      )

    Process.monitor(tts)

    {:ok, pid} = Worker.start_link({cycle, config})
    Process.monitor(pid)

    assign(socket,
      head_id: head_id,
      worker_pid: pid,
      tts: tts,
      responding: true,
      claude_response: ""
    )
  end

  defp next_counter(socket) do
    c = socket.assigns.transcript_counter + 1
    {c, assign(socket, transcript_counter: c)}
  end
end
