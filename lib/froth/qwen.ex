defmodule Froth.Qwen do
  @moduledoc """
  WebSocket client for Qwen realtime APIs (ASR and TTS).

  Uses `WsProto.Client` for the WebSocket connection, which keeps an
  explicit send queue and never blocks on TLS writes.

  ## ASR

      {:ok, pid} = Froth.Qwen.start_link(
        topic: "asr:xxx",
        model: "qwen3-asr-flash-realtime-2026-02-10",
        audio_topic: "audio:xxx",
        session: %{
          modalities: ["text"],
          input_audio_format: "pcm",
          sample_rate: 16_000,
          input_audio_transcription: %{language: "en"},
          turn_detection: %{type: "server_vad", threshold: 0.2, silence_duration_ms: 800}
        }
      )

  Broadcasts on topic: `{:asr_text, map}`, `{:asr_completed, map}`,
  `{:asr_speech_started, ms}`, `{:asr_speech_stopped, ms}`

  ## TTS

      {:ok, pid} = Froth.Qwen.start_link(
        topic: "tts:xxx",
        model: "qwen3-tts-flash-realtime",
        output_stream: %Voice.Stream{},
        session: %{
          mode: "server_commit",
          voice: "Cherry",
          response_format: "pcm",
          sample_rate: 24_000,
          language_type: "Auto"
        }
      )

  Broadcasts on topic: `{:tts_audio, binary}`, `:tts_response_done`
  """

  use GenServer

  alias Froth.SpeexResample
  alias Froth.Telemetry.Span

  @host "dashscope-intl.aliyuncs.com"
  @resample_quality 5

  defstruct [
    :ws_client,
    :topic,
    :session,
    :audio_topic,
    :head,
    :asr_target_rate,
    :asr_input_rate,
    :asr_resampler,
    :kind,
    audio_subscribed?: false,
    session_ready?: false,
    pre_session_audio_frames: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_event(pid, event) when is_pid(pid) and is_map(event) do
    GenServer.cast(pid, {:client_event, event})
  end

  def send_event(_pid, _event), do: :ok

  # -- Init -------------------------------------------------------------------

  @impl true
  def init(opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ALIBABA_API_KEY")
    topic = Keyword.fetch!(opts, :topic)
    model = Keyword.fetch!(opts, :model)
    session = Keyword.fetch!(opts, :session)
    audio_topic = Keyword.get(opts, :audio_topic)
    output_stream = Keyword.get(opts, :output_stream)
    head = if output_stream, do: Voice.Stream.write_head(output_stream)
    asr_target_rate = session_sample_rate(session)
    kind = if audio_topic, do: :asr, else: if(output_stream, do: :tts, else: :generic)

    ws_url = Keyword.get(opts, :ws_url)

    uri =
      if ws_url,
        do: "#{ws_url}/api-ws/v1/realtime?model=#{model}",
        else: "wss://#{@host}/api-ws/v1/realtime?model=#{model}"

    {:ok, ws_client} =
      WsProto.Client.start_link(uri,
        headers: [{"authorization", "Bearer #{api_key}"}],
        caller: self()
      )

    Process.monitor(ws_client)

    state = %__MODULE__{
      ws_client: ws_client,
      topic: topic,
      session: session,
      audio_topic: audio_topic,
      head: head,
      asr_target_rate: asr_target_rate,
      kind: kind
    }

    {:ok, state}
  end

  # -- WebSocket events from WsProto.Client -----------------------------------

  @impl true
  def handle_info({:ws, _pid, :connected}, state) do
    Span.execute([:froth, :qwen, :connected], nil, %{kind: state.kind, topic: state.topic})
    state = maybe_subscribe_audio_source(state)

    WsProto.Client.send(
      state.ws_client,
      {:text, encode(%{type: "session.update", session: state.session})}
    )

    {:noreply, state}
  end

  def handle_info({:ws, _pid, {:text, json}}, state) do
    case Jason.decode(json) do
      {:ok, event} ->
        Span.execute([:froth, :qwen, :in], nil, %{
          kind: state.kind,
          type: event["type"],
          stash: event["stash"],
          transcript: event["transcript"],
          item_id: event["item_id"],
          audio_start_ms: event["audio_start_ms"],
          audio_end_ms: event["audio_end_ms"]
        })

        handle_event(event, state)

      {:error, reason} ->
        emit_ws_error(state, %{
          kind: state.kind,
          type: :json_decode,
          error: format_reason(reason),
          raw_preview: String.slice(json, 0, 200)
        })

        {:noreply, state}
    end
  end

  def handle_info({:ws, _pid, {:close, code, reason}}, state) do
    Span.execute([:froth, :qwen, :ws_closed], nil, %{kind: state.kind, code: code, reason: reason})

    {:stop, :normal, state}
  end

  def handle_info({:ws, _pid, {:error, reason}}, state) do
    emit_ws_error(state, %{kind: state.kind, type: :transport, error: format_reason(reason)})
    {:stop, reason, state}
  end

  def handle_info({:ws, _pid, _frame}, state), do: {:noreply, state}

  # -- WsProto.Client process died --------------------------------------------

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{ws_client: pid} = state) do
    Span.execute([:froth, :qwen, :ws_client_down], nil, %{
      kind: state.kind,
      reason: inspect(reason)
    })

    {:stop, reason, state}
  end

  # -- PubSub audio frames ----------------------------------------------------

  def handle_info(%{pcm: pcm}, %{session_ready?: false} = state) when is_binary(pcm) do
    count = state.pre_session_audio_frames + 1

    if count == 1 do
      Span.execute([:froth, :qwen, :audio_before_session], nil, %{
        kind: state.kind,
        topic: state.topic,
        bytes: byte_size(pcm)
      })
    end

    {:noreply, %{state | pre_session_audio_frames: count}}
  end

  def handle_info(%{pcm: pcm} = packet, state) when is_binary(pcm) do
    if state.pre_session_audio_frames > 0 do
      Span.execute([:froth, :qwen, :audio_resumed], nil, %{
        kind: state.kind,
        topic: state.topic,
        dropped_frames: state.pre_session_audio_frames
      })
    end

    input_rate = packet_sample_rate(packet)

    if input_rate != state.asr_input_rate do
      Span.execute([:froth, :qwen, :audio_rate_change], nil, %{
        kind: state.kind,
        input_rate: input_rate,
        target_rate: state.asr_target_rate
      })
    end

    {pcm, state} = maybe_resample_input_audio(pcm, input_rate, state)

    WsProto.Client.send(
      state.ws_client,
      {:text, encode(%{type: "input_audio_buffer.append", audio: Base.encode64(pcm)})}
    )

    {:noreply, %{state | pre_session_audio_frames: 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Casts from external callers --------------------------------------------

  @impl true
  def handle_cast({:client_event, event}, state) do
    WsProto.Client.send(state.ws_client, {:text, encode(event)})
    {:noreply, state}
  end

  # -- Qwen protocol events ---------------------------------------------------

  defp handle_event(%{"type" => "session.finished"}, state) do
    broadcast(state, :qwen_ws_finished)
    WsProto.Client.send(state.ws_client, {:close, 1000, ""})
    {:stop, :normal, state}
  end

  defp handle_event(%{"type" => "error", "error" => error}, state) do
    emit_ws_error(state, %{kind: state.kind, type: :api, error: error})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "session.created", "session" => session}, state) do
    Span.execute([:froth, :qwen, :session_created], nil, %{
      kind: state.kind,
      session_id: session["id"],
      model: session["model"]
    })

    {:noreply, state}
  end

  defp handle_event(%{"type" => "session.updated", "session" => session}, state) do
    Span.execute([:froth, :qwen, :session_updated], nil, %{
      kind: state.kind,
      session_id: session["id"],
      model: session["model"]
    })

    {:noreply, %{state | session_ready?: true}}
  end

  # ASR events
  defp handle_event(%{"type" => "conversation.item.input_audio_transcription.text"} = e, state) do
    broadcast(
      state,
      {:asr_text,
       %{text: e["text"], stash: e["stash"], language: e["language"], emotion: e["emotion"]}}
    )

    {:noreply, state}
  end

  defp handle_event(
         %{"type" => "conversation.item.input_audio_transcription.completed"} = e,
         state
       ) do
    broadcast(
      state,
      {:asr_completed,
       %{
         transcript: e["transcript"],
         language: e["language"],
         emotion: e["emotion"],
         item_id: e["item_id"]
       }}
    )

    {:noreply, state}
  end

  defp handle_event(
         %{"type" => "input_audio_buffer.speech_started", "audio_start_ms" => ms},
         state
       ) do
    broadcast(state, {:asr_speech_started, ms})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "input_audio_buffer.speech_stopped", "audio_end_ms" => ms}, state) do
    broadcast(state, {:asr_speech_stopped, ms})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "conversation.item.created", "item" => item}, state) do
    Span.execute([:froth, :qwen, :item_created], nil, %{kind: state.kind, item_id: item["id"]})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "input_audio_buffer.committed", "item_id" => item_id}, state) do
    Span.execute([:froth, :qwen, :audio_committed], nil, %{kind: state.kind, item_id: item_id})
    {:noreply, state}
  end

  # TTS events
  defp handle_event(%{"type" => "response.audio.delta", "delta" => b64}, state) do
    audio = Base.decode64!(b64)
    state = if state.head, do: %{state | head: Voice.Stream.push(state.head, audio)}, else: state
    broadcast(state, {:tts_audio, audio})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "response.done"}, state) do
    broadcast(state, :tts_response_done)
    {:noreply, state}
  end

  defp handle_event(%{"type" => type}, state) do
    Span.execute([:froth, :qwen, :unhandled_event], nil, %{kind: state.kind, type: type})
    {:noreply, state}
  end

  # -- Helpers ----------------------------------------------------------------

  defp broadcast(state, msg) do
    Phoenix.PubSub.broadcast(Froth.PubSub, state.topic, msg)
  end

  defp maybe_subscribe_audio_source(%{audio_topic: topic, audio_subscribed?: false} = state)
       when is_binary(topic) do
    Phoenix.PubSub.subscribe(Froth.PubSub, topic)
    %{state | audio_subscribed?: true}
  end

  defp maybe_subscribe_audio_source(state), do: state

  defp emit_ws_error(state, payload) do
    Span.execute([:froth, :qwen, :ws_error], nil, %{kind: state.kind, payload: payload})
    broadcast(state, {:qwen_ws_error, payload})
  end

  defp maybe_resample_input_audio(pcm, _input_rate, %{asr_target_rate: nil} = state),
    do: {pcm, state}

  defp maybe_resample_input_audio(pcm, nil, state), do: {pcm, state}

  defp maybe_resample_input_audio(pcm, input_rate, %{asr_target_rate: target_rate} = state)
       when input_rate == target_rate do
    {pcm, %{state | asr_input_rate: input_rate}}
  end

  defp maybe_resample_input_audio(pcm, input_rate, %{asr_target_rate: target_rate} = state) do
    with {:ok, state} <- ensure_asr_resampler(state, input_rate, target_rate),
         {:ok, out_pcm} <- SpeexResample.process(state.asr_resampler, pcm) do
      {out_pcm, state}
    else
      {:error, reason} ->
        Span.execute([:froth, :qwen, :resample_failed], nil, %{
          input_rate: input_rate,
          target_rate: target_rate,
          reason: inspect(reason)
        })

        {pcm, state}
    end
  end

  defp ensure_asr_resampler(
         %{asr_resampler: resampler, asr_input_rate: input_rate} = state,
         input_rate,
         _target_rate
       )
       when not is_nil(resampler) do
    {:ok, state}
  end

  defp ensure_asr_resampler(state, input_rate, target_rate) do
    case SpeexResample.new(1, input_rate, target_rate, @resample_quality) do
      {:ok, resampler} -> {:ok, %{state | asr_resampler: resampler, asr_input_rate: input_rate}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp packet_sample_rate(packet) do
    rate = Map.get(packet, :rate) || Map.get(packet, "rate")
    if is_integer(rate) and rate > 0, do: rate
  end

  defp session_sample_rate(session) when is_map(session) do
    rate = Map.get(session, :sample_rate) || Map.get(session, "sample_rate")
    if is_integer(rate) and rate > 0, do: rate
  end

  defp format_reason(reason) do
    inspect(reason, pretty: false, limit: 25, printable_limit: 200)
  end

  defp encode(event) do
    event = Map.put(event, :event_id, "event_#{System.os_time(:millisecond)}")
    type = event[:type] || event["type"]

    if type != "input_audio_buffer.append" do
      log_event = Map.delete(event, :audio)
      Span.execute([:froth, :qwen, :out], nil, %{kind: type, payload: log_event})
    end

    Jason.encode!(event)
  end
end
