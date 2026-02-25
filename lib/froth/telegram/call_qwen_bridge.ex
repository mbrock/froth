defmodule Froth.Telegram.CallQwenBridge do
  @moduledoc """
  Real-time Qwen ASR/TTS bridge for a Telegram private call.

  Features:
  - Subscribes to call audio and streams it to Qwen ASR.
  - Logs partial/final transcripts with `Logger`.
  - Streams Qwen TTS audio back into the call.

  This module is designed for quick call testing and demo flows.

  ## Usage

      {:ok, pid} =
        Froth.Telegram.CallQwenBridge.start_link(
          session_id: "my_session",
          call_id: 123,
          initial_text: "Hello there, I am testing."
        )

      Froth.Telegram.CallQwenBridge.say(pid, "Can you hear me?")

  Optional `:subscriber` receives forwarded messages:
  - `{:call_qwen_transcript_partial, call_id, text, stash}`
  - `{:call_qwen_transcript_final, call_id, transcript}`
  - `{:call_qwen_media_event, call_id, event}`
  - `{:call_qwen_media_error, call_id, reason}`
  """

  use GenServer

  require Logger

  alias Froth.Qwen
  alias Froth.SpeexResample
  alias Froth.Telegram.Calls

  @default_initial_text "Hello there, I am testing."
  @speex_quality 5

  @type start_opt ::
          {:session_id, String.t()}
          | {:call_id, integer()}
          | {:name, GenServer.name()}
          | {:subscriber, pid()}
          | {:language, String.t()}
          | {:voice, String.t()}
          | {:asr_mode, :vad | :manual}
          | {:tts_mode, :commit | :server_commit}
          | {:log_partials, boolean()}
          | {:log_speech_events, boolean()}
          | {:initial_text, String.t() | nil}

  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec say(pid(), String.t()) :: :ok
  def say(pid, text) when is_pid(pid) and is_binary(text) do
    GenServer.cast(pid, {:say, text})
  end

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    call_id = Keyword.fetch!(opts, :call_id)
    subscriber = Keyword.get(opts, :subscriber)
    language = Keyword.get(opts, :language, "en")
    voice = Keyword.get(opts, :voice, "Cherry")
    asr_mode = Keyword.get(opts, :asr_mode, :vad)
    tts_mode = Keyword.get(opts, :tts_mode, :server_commit)
    log_partials = Keyword.get(opts, :log_partials, true)
    log_speech_events = Keyword.get(opts, :log_speech_events, true)
    initial_text = Keyword.get(opts, :initial_text, @default_initial_text)
    bridge_id = System.unique_integer([:positive, :monotonic])
    asr_topic = "call_qwen:asr:#{call_id}:#{bridge_id}"
    tts_topic = "call_qwen:tts:#{call_id}:#{bridge_id}"

    with :ok <- ensure_ok(Calls.start_private_media(call_id, self())),
         {:ok, down_resampler} <- SpeexResample.new(1, 48_000, 16_000, @speex_quality),
         {:ok, up_resampler} <- SpeexResample.new(1, 24_000, 48_000, @speex_quality),
         :ok <- Phoenix.PubSub.subscribe(Froth.PubSub, asr_topic),
         :ok <- Phoenix.PubSub.subscribe(Froth.PubSub, tts_topic),
         {:ok, asr_pid} <-
           Qwen.start_link(
             topic: asr_topic,
             model: "qwen3-asr-flash-realtime-2026-02-10",
             session: asr_session(language, asr_mode)
           ),
         {:ok, tts_pid} <-
           Qwen.start_link(
             topic: tts_topic,
             model: "qwen3-tts-flash-realtime",
             session: tts_session(voice, tts_mode)
           ) do
      state = %{
        session_id: session_id,
        call_id: call_id,
        subscriber: subscriber,
        asr_pid: asr_pid,
        tts_pid: tts_pid,
        asr_mode: asr_mode,
        tts_mode: tts_mode,
        asr_ref: Process.monitor(asr_pid),
        tts_ref: Process.monitor(tts_pid),
        down_resampler: down_resampler,
        up_resampler: up_resampler,
        last_partial: "",
        log_partials: log_partials,
        log_speech_events: log_speech_events
      }

      if is_binary(initial_text) and String.trim(initial_text) != "" do
        send(self(), {:say_now, initial_text})
      end

      Logger.info(
        event: :call_qwen_bridge_started,
        session_id: session_id,
        call_id: call_id,
        language: language,
        voice: voice,
        log_partials: log_partials,
        log_speech_events: log_speech_events
      )

      publish_event(state, :bridge_started, %{
        language: language,
        voice: voice,
        log_partials: log_partials,
        log_speech_events: log_speech_events
      })

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    publish_event(state, :bridge_stopped, %{reason: inspect(reason)})
    _ = Calls.unsubscribe_call_audio(state.call_id, self())
    _ = safe_stop(state.asr_pid)
    _ = safe_stop(state.tts_pid)
    :ok
  end

  @impl GenServer
  def handle_cast({:say, text}, state) when is_binary(text) do
    do_tts(text, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:say_now, text}, state) when is_binary(text) do
    do_tts(text, state)
    {:noreply, state}
  end

  def handle_info({:call_audio, call_id, pcm_48k}, %{call_id: call_id} = state)
      when is_binary(pcm_48k) do
    state = stream_to_asr(state, pcm_48k)
    {:noreply, state}
  end

  def handle_info({:call_media_event, call_id, event}, %{call_id: call_id} = state) do
    Logger.info(event: :call_qwen_media_event, call_id: call_id, media_event: event)
    publish_event(state, :media_event, %{media_event: event})
    maybe_notify(state.subscriber, {:call_qwen_media_event, call_id, event})
    {:noreply, state}
  end

  def handle_info({:call_media_error, call_id, reason}, %{call_id: call_id} = state) do
    Logger.warning(event: :call_qwen_media_error, call_id: call_id, reason: reason)
    publish_event(state, :media_error, %{reason: inspect(reason)})
    maybe_notify(state.subscriber, {:call_qwen_media_error, call_id, reason})
    {:noreply, state}
  end

  def handle_info({event, pcm_24k}, state)
      when event in [:tts_audio, :qwen_tts_audio] and is_binary(pcm_24k) do
    with {:ok, pcm_48k} <- SpeexResample.process(state.up_resampler, pcm_24k) do
      case Calls.feed_pcm_frame(state.call_id, pcm_48k) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(event: :call_qwen_feed_failed, call_id: state.call_id, reason: reason)
          publish_event(state, :feed_failed, %{reason: inspect(reason)})
      end
    end

    {:noreply, state}
  end

  def handle_info(event, state) when event in [:tts_response_done, :qwen_tts_response_done] do
    Logger.info(event: :call_qwen_tts_done, call_id: state.call_id)
    publish_event(state, :tts_done)
    {:noreply, state}
  end

  def handle_info({event, msg}, state)
      when event in [:asr_text, :qwen_asr_text] and is_map(msg) do
    text = Map.get(msg, :text) || Map.get(msg, "text") || ""
    stash = Map.get(msg, :stash) || Map.get(msg, "stash") || ""
    partial = String.trim("#{text} #{stash}")

    state =
      if partial != "" and partial != state.last_partial do
        if state.log_partials do
          Logger.info(
            event: :call_qwen_asr_partial,
            call_id: state.call_id,
            text: text,
            stash: stash
          )
        end

        maybe_notify(
          state.subscriber,
          {:call_qwen_transcript_partial, state.call_id, text, stash}
        )

        publish_event(state, :asr_partial, %{text: text, stash: stash})

        %{state | last_partial: partial}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({event, msg}, state)
      when event in [:asr_completed, :qwen_asr_completed] and is_map(msg) do
    transcript =
      msg
      |> Map.get(:transcript, Map.get(msg, "transcript", ""))
      |> String.trim()

    if transcript != "" do
      Logger.info(event: :call_qwen_asr_final, call_id: state.call_id, transcript: transcript)
      maybe_notify(state.subscriber, {:call_qwen_transcript_final, state.call_id, transcript})
      publish_event(state, :asr_final, %{transcript: transcript})
    end

    {:noreply, %{state | last_partial: ""}}
  end

  def handle_info({event, ms}, state)
      when event in [:asr_speech_started, :qwen_asr_speech_started] do
    if state.log_speech_events do
      Logger.info(event: :call_qwen_asr_speech_started, call_id: state.call_id, ms: ms)
      publish_event(state, :asr_speech_started, %{ms: ms})
    end

    {:noreply, state}
  end

  def handle_info({event, ms}, state)
      when event in [:asr_speech_stopped, :qwen_asr_speech_stopped] do
    if state.log_speech_events do
      Logger.info(event: :call_qwen_asr_speech_stopped, call_id: state.call_id, ms: ms)
      publish_event(state, :asr_speech_stopped, %{ms: ms})
    end

    {:noreply, state}
  end

  def handle_info({:qwen_ws_error, reason}, state) do
    Logger.warning(event: :call_qwen_ws_error, call_id: state.call_id, reason: reason)
    publish_event(state, :ws_error, %{reason: inspect(reason)})
    {:noreply, state}
  end

  def handle_info(:qwen_ws_finished, state) do
    Logger.info(event: :call_qwen_ws_finished, call_id: state.call_id)
    publish_event(state, :ws_finished)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{asr_ref: ref} = state) do
    Logger.warning(event: :call_qwen_asr_down, call_id: state.call_id, reason: reason)
    publish_event(state, :asr_down, %{reason: inspect(reason)})
    {:stop, {:asr_down, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tts_ref: ref} = state) do
    Logger.warning(event: :call_qwen_tts_down, call_id: state.call_id, reason: reason)
    publish_event(state, :tts_down, %{reason: inspect(reason)})
    {:stop, {:tts_down, reason}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp do_tts(text, state) do
    trimmed = String.trim(text)

    if trimmed != "" do
      Logger.info(event: :call_qwen_tts_say, call_id: state.call_id, text: trimmed)
      publish_event(state, :tts_say, %{text: trimmed})
      Qwen.send_event(state.tts_pid, %{type: "input_text_buffer.append", text: trimmed})
      Qwen.send_event(state.tts_pid, %{type: "input_text_buffer.commit"})

      if state.tts_mode == :commit do
        Qwen.send_event(state.tts_pid, %{type: "response.create"})
      end
    end
  end

  defp publish_event(state, event, attrs \\ %{}) do
    payload =
      attrs
      |> Map.put(:event, event)
      |> Map.put(:session_id, state.session_id)
      |> Map.put(:call_id, state.call_id)

    _ =
      Froth.broadcast(
        bridge_topic(state.session_id, state.call_id),
        {:call_qwen_bridge_event, payload}
      )

    :ok
  rescue
    _ -> :ok
  end

  defp bridge_topic(session_id, call_id) when is_binary(session_id) and is_integer(call_id) do
    "call_qwen:#{session_id}:#{call_id}"
  end

  defp stream_to_asr(state, pcm_48k) do
    with {:ok, pcm_16k} when byte_size(pcm_16k) > 0 <-
           SpeexResample.process(state.down_resampler, pcm_48k) do
      Qwen.send_event(state.asr_pid, %{
        type: "input_audio_buffer.append",
        audio: Base.encode64(pcm_16k)
      })
    end

    state
  end

  defp asr_session(language, asr_mode) do
    session = %{
      modalities: ["text"],
      input_audio_format: "pcm",
      sample_rate: 16_000,
      input_audio_transcription: %{language: language}
    }

    case asr_mode do
      :manual ->
        session

      _ ->
        Map.put(session, :turn_detection, %{
          type: "server_vad",
          threshold: 0.2,
          silence_duration_ms: 800
        })
    end
  end

  defp tts_session(voice, tts_mode) do
    mode =
      case tts_mode do
        :commit -> "commit"
        _ -> "server_commit"
      end

    %{
      mode: mode,
      voice: voice,
      response_format: "pcm",
      sample_rate: 24_000,
      language_type: "Auto"
    }
  end

  defp ensure_ok(:ok), do: :ok
  defp ensure_ok({:ok, :ok}), do: :ok
  defp ensure_ok({:error, reason}), do: {:error, reason}
  defp ensure_ok(other), do: {:error, other}

  defp maybe_notify(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp maybe_notify(_, _), do: :ok

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp safe_stop(_), do: :ok
end
