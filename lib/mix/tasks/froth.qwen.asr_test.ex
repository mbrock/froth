defmodule Mix.Tasks.Froth.Qwen.AsrTest do
  @shortdoc "Stream PCM to Qwen ASR and log events with timestamps"
  @moduledoc """
  Streams audio to Qwen ASR via PubSub (same path as the real app) and prints
  all events with wall-clock timestamps.

      mix froth.qwen.asr_test --file /tmp/test_speech_16k.raw
      mix froth.qwen.asr_test --file /tmp/lex_voice.mp3
  """

  use Mix.Task
  require Logger

  @sample_rate 16_000
  @chunk_samples 4096

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [file: :string, rate: :integer],
        aliases: [f: :file, r: :rate]
      )

    file = opts[:file] || Mix.raise("--file is required")
    send_rate = opts[:rate] || @sample_rate

    ensure_started!()
    load_dotenv()

    pcm = file_to_pcm(file, send_rate)
    chunk_bytes = @chunk_samples * 2
    chunk_ms = div(@chunk_samples * 1000, send_rate)
    chunks = for <<chunk::binary-size(chunk_bytes) <- pcm>>, do: chunk
    duration_s = div(byte_size(pcm), send_rate * 2)

    topic = "asr:test-#{System.os_time(:millisecond)}"
    audio_topic = "audio:test-#{System.os_time(:millisecond)}"
    Phoenix.PubSub.subscribe(Froth.PubSub, topic)

    info("#{length(chunks)} chunks (~#{duration_s}s) at #{send_rate}Hz, #{chunk_ms}ms/chunk")
    t0 = System.monotonic_time(:millisecond)

    {:ok, pid} =
      Froth.Qwen.start_link(
        topic: topic,
        model: "qwen3-asr-flash-realtime-2026-02-10",
        audio_topic: audio_topic,
        session: %{
          modalities: ["text"],
          input_audio_format: "pcm",
          sample_rate: @sample_rate,
          input_audio_transcription: %{language: "en"},
          turn_detection: %{type: "server_vad", threshold: 0.2, silence_duration_ms: 800}
        }
      )

    ref = Process.monitor(pid)
    Process.sleep(2_000)

    for {chunk, i} <- Enum.with_index(chunks), Process.alive?(pid) do
      packet = %{pcm: chunk, rate: send_rate, stream_id: "test", seq: i, ts_ms: i * chunk_ms}
      Phoenix.PubSub.broadcast(Froth.PubSub, audio_topic, packet)
      Process.sleep(chunk_ms)
      drain_events(t0)
    end

    info("[#{elapsed(t0)}] streaming done, waiting for remaining events...")
    wait_until_done(t0, ref, 5_000)
  end

  defp wait_until_done(t0, ref, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(t0, ref, deadline)
  end

  defp wait_loop(t0, ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, _, reason} ->
        drain_events(t0)
        info("[#{elapsed(t0)}] done (#{inspect(reason)})")

      msg ->
        log_event(t0, msg)
        wait_loop(t0, ref, deadline)
    after
      remaining -> info("[#{elapsed(t0)}] timeout")
    end
  end

  defp drain_events(t0) do
    receive do
      msg ->
        log_event(t0, msg)
        drain_events(t0)
    after
      0 -> :ok
    end
  end

  defp log_event(t0, msg) do
    ts = elapsed(t0)

    case msg do
      {:asr_text, %{stash: s}} -> info("[#{ts}] partial: #{s}")
      {:asr_completed, %{transcript: t}} -> info("[#{ts}] COMPLETED: #{t}")
      {:asr_speech_started, ms} -> info("[#{ts}] speech_started (audio_ms=#{ms})")
      {:asr_speech_stopped, ms} -> info("[#{ts}] speech_stopped (audio_ms=#{ms})")
      :qwen_ws_finished -> info("[#{ts}] session_finished")
      {:qwen_ws_error, p} -> info("[#{ts}] error: #{inspect(p, limit: 5)}")
      _ -> :ok
    end
  end

  defp elapsed(t0) do
    ms = System.monotonic_time(:millisecond) - t0
    "#{Float.round(ms / 1000, 1)}s"
  end

  defp file_to_pcm(path, rate) do
    if String.ends_with?(path, ".raw") or String.ends_with?(path, ".pcm") do
      File.read!(path)
    else
      {pcm, 0} =
        System.cmd("ffmpeg", [
          "-i",
          path,
          "-ar",
          "#{rate}",
          "-ac",
          "1",
          "-f",
          "s16le",
          "-acodec",
          "pcm_s16le",
          "-v",
          "error",
          "-"
        ])

      pcm
    end
  end

  defp load_dotenv do
    env_path = Path.join(File.cwd!(), ".env")

    if File.exists?(env_path) do
      env_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, val] ->
            val = val |> String.trim() |> String.trim("'") |> String.trim("\"")
            System.put_env(String.trim(key), val)

          _ ->
            :ok
        end
      end)
    end
  end

  defp ensure_started! do
    for app <- [:req, :fresh, :phoenix_pubsub] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    unless Process.whereis(Froth.PubSub) do
      {:ok, _} =
        Supervisor.start_link([{Phoenix.PubSub, name: Froth.PubSub}], strategy: :one_for_one)
    end
  end

  defp info(msg), do: Mix.shell().info(msg)
end
