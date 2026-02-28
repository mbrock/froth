defmodule FrothWeb.RoomChannel do
  @moduledoc """
  A room that participants join to exchange audio.

  Each participant declares an input stream (what they contribute) and
  output streams (what they listen to) via join params. Streams are
  `Voice.Stream` records identified by UUID.

  Binary frames from the client are stamped and broadcast on the input
  stream's PubSub topic. Audio from subscribed output streams is pushed
  to the client as `"pcm"`.

  The channel also manages the Qwen ASR process: the client sends
  `"start_asr"` / `"stop_asr"` events to control the ASR lifecycle.
  """

  use Phoenix.Channel

  alias Froth.Qwen
  alias Froth.Telemetry.Span

  @impl true
  def join("room:" <> room_id, params, socket) do
    input_id = params["input"]
    output_ids = params["outputs"] || []

    Span.execute([:froth, :web, :room_joined], nil, %{
      room_id: room_id,
      input_id: input_id,
      output_ids: output_ids
    })

    for id <- output_ids, do: Voice.Stream.subscribe(id)

    head =
      if input_id do
        stream = Froth.Repo.get!(Voice.Stream, input_id)
        Voice.Stream.write_head(stream)
      end

    {:ok, assign(socket, head: head, asr: nil)}
  end

  @impl true
  def handle_in("audio", {:binary, pcm}, %{assigns: %{head: head}} = socket) when head != nil do
    head = Voice.Stream.push(head, pcm)
    {:noreply, assign(socket, head: head)}
  end

  def handle_in(
        "audio_config",
        %{"sample_rate" => sample_rate},
        %{assigns: %{head: head}} = socket
      )
      when head != nil do
    case parse_sample_rate(sample_rate) do
      {:ok, rate} ->
        Span.execute([:froth, :web, :sample_rate_changed], nil, %{rate: rate})
        {:noreply, assign(socket, head: %{head | rate: rate})}

      :error ->
        Span.execute([:froth, :web, :invalid_sample_rate], nil, %{
          sample_rate: inspect(sample_rate)
        })

        {:noreply, socket}
    end
  end

  def handle_in("start_asr", payload, %{assigns: %{head: head}} = socket) when head != nil do
    if socket.assigns.asr do
      {:reply, {:ok, %{status: "already_running"}}, socket}
    else
      asr_topic = "asr:#{head.id}"
      audio_topic = Voice.Stream.topic(head.id)

      qwen_opts =
        [
          topic: asr_topic,
          model: "qwen3-asr-flash-realtime-2026-02-10",
          audio_topic: audio_topic,
          session: %{
            modalities: ["text"],
            input_audio_format: "pcm",
            sample_rate: 16_000,
            input_audio_transcription: %{language: "en"},
            turn_detection: %{type: "server_vad", threshold: 0, silence_duration_ms: 400}
          }
        ] ++
          if(payload["fake"], do: [ws_url: "ws://localhost:8765"], else: [])

      case Qwen.start_link(qwen_opts) do
        {:ok, asr} ->
          Process.monitor(asr)
          Span.execute([:froth, :web, :asr_started], nil, %{stream_id: head.id})
          {:reply, {:ok, %{status: "started"}}, assign(socket, asr: asr)}

        {:error, reason} ->
          Span.execute([:froth, :web, :asr_start_failed], nil, %{reason: inspect(reason)})
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    end
  end

  def handle_in("commit_audio", _payload, socket) do
    if socket.assigns.asr do
      Qwen.send_event(socket.assigns.asr, %{type: "input_audio_buffer.commit"})
      Span.execute([:froth, :web, :asr_buffer_committed], nil, %{})
    end

    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("stop_asr", _payload, socket) do
    if socket.assigns.asr do
      Qwen.send_event(socket.assigns.asr, %{type: "session.finish"})
      Span.execute([:froth, :web, :asr_stopped], nil, %{})
    end

    {:reply, {:ok, %{}}, assign(socket, asr: nil)}
  end

  def handle_in(event, _payload, socket) do
    Span.execute([:froth, :web, :unhandled_channel_event], nil, %{event: inspect(event)})
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{pcm: pcm}, socket) do
    push(socket, "pcm", {:binary, pcm})
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket) do
    if pid == socket.assigns.asr do
      Span.execute([:froth, :web, :asr_process_died], nil, %{reason: inspect(reason)})
      {:noreply, assign(socket, asr: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:asr] do
      Qwen.send_event(socket.assigns.asr, %{type: "session.finish"})
    end

    :ok
  end

  defp parse_sample_rate(rate) when is_integer(rate) and rate >= 8_000 and rate <= 96_000,
    do: {:ok, rate}

  defp parse_sample_rate(rate) when is_binary(rate) do
    case Integer.parse(rate) do
      {int, ""} -> parse_sample_rate(int)
      _ -> :error
    end
  end

  defp parse_sample_rate(_), do: :error
end
