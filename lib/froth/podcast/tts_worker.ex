defmodule Froth.Podcast.TtsWorker do
  @moduledoc """
  Oban worker for a single TTS segment in a podcast.

  Generates one audio segment via Replicate, downloads the result,
  and saves it to disk. Retries automatically on rate limits.
  """
  use Oban.Worker, queue: :podcast, max_attempts: 10

  alias Froth.Telemetry.Span

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: 5s, 10s, 20s, 40s, ...
    trunc(:math.pow(2, attempt - 1) * 5)
  end

  @impl true
  def perform(%Oban.Job{args: %{"is_file" => true} = args}) do
    # File embed — already copied to segment path at generate time
    send_progress(args)
    maybe_stitch(args["batch_id"])
    :ok
  end

  @impl true
  def perform(%Oban.Job{args: args}) do
    %{
      "batch_id" => batch_id,
      "index" => idx,
      "speaker" => speaker,
      "text" => text,
      "voice_id" => voice_id,
      "model" => model,
      "language" => language
    } = args

    emotion = args["emotion"]
    seg_path = segment_path(batch_id, idx)

    input = %{text: text, voice_id: voice_id, language_boost: language}
    input = if emotion, do: Map.put(input, :emotion, emotion), else: input

    opts_list = [model: model] ++ Enum.to_list(input)

    with {:ok, p} <- Froth.Replicate.start("#{speaker}_#{idx}", opts_list),
         {:ok, p} <- Froth.Replicate.await(p.id, 120_000) do
      url = extract_url(p.output)

      case Finch.request(Finch.build(:get, url), Froth.Finch, receive_timeout: 30_000) do
        {:ok, %Finch.Response{status: 200, body: audio}} ->
          File.write!(seg_path, audio)

          Span.execute([:froth, :podcast, :segment_done], nil, %{
            batch_id: batch_id,
            index: idx,
            speaker: speaker,
            bytes: byte_size(audio)
          })

          send_progress(args)

          # Check if all segments for this batch are done
          maybe_stitch(batch_id)
          :ok

        {:ok, %Finch.Response{status: status}} ->
          {:error, "download failed: HTTP #{status}"}

        {:error, err} ->
          {:error, "download failed: #{inspect(err)}"}
      end
    else
      {:error, {:http_error, 429, _}} ->
        {:snooze, 10}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def segment_path(batch_id, idx) do
    "/tmp/podcast_#{batch_id}_#{idx |> Integer.to_string() |> String.pad_leading(3, "0")}.mp3"
  end

  defp maybe_stitch(batch_id) do
    import Ecto.Query

    # Count jobs not yet completed (excluding the current one which is still "executing")
    pending =
      Froth.Repo.one(
        from(j in Oban.Job,
          where: j.worker == "Froth.Podcast.TtsWorker",
          where: fragment("args->>'batch_id' = ?", ^batch_id),
          where: j.state not in ["completed", "executing"],
          select: count()
        )
      )

    # If nothing is pending or running (besides us), we're the last one
    if pending == 0 do
      # Use unique to avoid duplicate stitch jobs
      %{"batch_id" => batch_id}
      |> Froth.Podcast.StitchWorker.new(unique: [period: 300, keys: [:batch_id]])
      |> Oban.insert()
    end
  end

  defp send_progress(%{"batch_id" => batch_id, "chat_id" => chat_id, "label" => label}) do
    import Ecto.Query

    total =
      Froth.Repo.one(
        from(j in Oban.Job,
          where: j.worker == "Froth.Podcast.TtsWorker",
          where: fragment("args->>'batch_id' = ?", ^batch_id),
          select: count()
        )
      )

    done =
      Froth.Repo.one(
        from(j in Oban.Job,
          where: j.worker == "Froth.Podcast.TtsWorker",
          where: fragment("args->>'batch_id' = ?", ^batch_id),
          where: j.state == "completed",
          select: count()
        )
      )

    label = label || "Podcast"

    if rem(done, max(div(total, 4), 1)) == 0 or done == total do
      Froth.Telegram.send("charlie", %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" => %{
          "@type" => "inputMessageText",
          "text" => %{
            "@type" => "formattedText",
            "text" => "#{label} — #{done}/#{total} segments rendered"
          }
        }
      })
    end
  end

  defp send_progress(_), do: :ok

  defp extract_url(%{"urls" => [url | _]}), do: url
  defp extract_url(%{"audio_file" => %{"url" => url}}), do: url
  defp extract_url(url) when is_binary(url), do: url

  defp extract_url(%{} = map) do
    cond do
      Map.has_key?(map, "urls") -> hd(map["urls"])
      Map.has_key?(map, "output") -> extract_url(map["output"])
      true -> raise "Cannot extract URL from output: #{inspect(map)}"
    end
  end
end
