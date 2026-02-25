defmodule Mix.Tasks.Froth.WsTest do
  @shortdoc "Smoke test WsProto.Client against Qwen"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:jason)

    api_key = System.get_env("ALIBABA_API_KEY")
    model = "qwen3-asr-flash-realtime-2026-02-10"
    url = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=#{model}"

    IO.puts("Connecting to #{url}...")

    {:ok, pid} =
      WsProto.Client.start_link(url,
        headers: [{"authorization", "Bearer #{api_key}"}],
        caller: self()
      )

    receive do
      {:ws, ^pid, :connected} -> IO.puts("CONNECTED!")
    after
      5000 ->
        IO.puts("TIMEOUT waiting for connect")
        System.halt(1)
    end

    session = %{
      type: "session.update",
      event_id: "e_test",
      session: %{
        modalities: ["text"],
        input_audio_format: "pcm",
        sample_rate: 16000,
        input_audio_transcription: %{language: "en"},
        turn_detection: %{type: "server_vad", threshold: 0.2, silence_duration_ms: 800}
      }
    }

    WsProto.Client.send(pid, {:text, Jason.encode!(session)})

    for i <- 1..2 do
      receive do
        {:ws, ^pid, {:text, text}} ->
          IO.puts("MSG #{i}: #{String.slice(text, 0, 300)}")

        {:ws, ^pid, other} ->
          IO.puts("MSG #{i}: #{inspect(other, limit: 5)}")
      after
        5000 -> IO.puts("TIMEOUT waiting for msg #{i}")
      end
    end

    IO.puts("\nqueue: #{inspect(WsProto.Client.queue_info(pid))}")
    Process.exit(pid, :kill)
    IO.puts("DONE")
  end
end
