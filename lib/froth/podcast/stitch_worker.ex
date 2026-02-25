defmodule Froth.Podcast.StitchWorker do
  @moduledoc """
  Oban worker that stitches completed TTS segments into a final podcast
  and sends it via Telegram.
  """
  use Oban.Worker, queue: :podcast, max_attempts: 3

  require Logger

  @default_pause_ms 300

  @impl true
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    import Ecto.Query

    # Load batch metadata
    meta =
      Froth.Repo.one(
        from(j in Oban.Job,
          where: j.worker == "Froth.Podcast.TtsWorker",
          where: fragment("args->>'batch_id' = ?", ^batch_id),
          order_by: fragment("(args->>'index')::int"),
          limit: 1,
          select: j.args
        )
      )

    if is_nil(meta) do
      {:error, "no segments found for batch #{batch_id}"}
    else
      chat_id = meta["chat_id"]
      label = meta["label"] || "Podcast"
      pause_ms = meta["pause_ms"] || @default_pause_ms
      bot_token = meta["bot_token"] || System.get_env("TELEGRAM_BOT_TOKEN")

      # Collect all segment paths in order
      segment_count =
        Froth.Repo.one(
          from(j in Oban.Job,
            where: j.worker == "Froth.Podcast.TtsWorker",
            where: fragment("args->>'batch_id' = ?", ^batch_id),
            select: count()
          )
        )

      seg_paths =
        0..(segment_count - 1)
        |> Enum.map(&Froth.Podcast.TtsWorker.segment_path(batch_id, &1))

      missing = Enum.reject(seg_paths, &File.exists?/1)

      if missing != [] do
        {:error, "missing segments: #{inspect(missing)}"}
      else
        stitch_and_send(seg_paths, pause_ms, chat_id, label, bot_token, batch_id)
      end
    end
  end

  defp stitch_and_send(seg_paths, pause_ms, chat_id, label, bot_token, batch_id) do
    total = length(seg_paths)
    send_progress(bot_token, chat_id, "#{label} — stitching #{total} segments...")

    # Generate pause file
    pause_path = "/tmp/podcast_pause_#{pause_ms}ms.mp3"

    unless File.exists?(pause_path) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=44100:cl=mono",
            "-t",
            "#{pause_ms / 1000}",
            "-c:a",
            "libmp3lame",
            "-q:a",
            "9",
            pause_path
          ],
          stderr_to_stdout: true
        )
    end

    output_path = "/tmp/podcast_#{batch_id}_final.mp3"
    concat_path = "/tmp/podcast_#{batch_id}_concat.txt"

    concat_lines =
      seg_paths
      |> Enum.intersperse(pause_path)
      |> Enum.map(&"file '#{&1}'")
      |> Enum.join("\n")

    File.write!(concat_path, concat_lines)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-f",
          "concat",
          "-safe",
          "0",
          "-i",
          concat_path,
          "-c:a",
          "libmp3lame",
          "-b:a",
          "128k",
          "-ar",
          "44100",
          output_path
        ],
        stderr_to_stdout: true
      )

    # Get duration
    {probe, 0} =
      System.cmd("ffprobe", [
        "-v",
        "quiet",
        "-show_entries",
        "format=duration",
        "-of",
        "csv=p=0",
        output_path
      ])

    duration = probe |> String.trim() |> String.to_float() |> round()
    minutes = div(duration, 60)
    seconds = rem(duration, 60)
    duration_str = "#{minutes}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"

    send_progress(bot_token, chat_id, "#{label} — uploading #{duration_str}...")
    Froth.Telegram.send_audio("charlie", chat_id, output_path, caption: label)
    send_progress(bot_token, chat_id, "#{label} — done. #{total} segments, #{duration_str}.")

    # Cleanup
    File.rm(concat_path)
    Enum.each(seg_paths, &File.rm/1)

    Logger.info(
      event: :podcast_complete,
      batch_id: batch_id,
      label: label,
      segments: total,
      duration: duration_str
    )

    :ok
  end

  defp send_progress(_bot_token, chat_id, text) do
    Froth.Telegram.send("charlie", %{
      "@type" => "sendMessage",
      "chat_id" => chat_id,
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => %{"@type" => "formattedText", "text" => text}
      }
    })
  end
end
