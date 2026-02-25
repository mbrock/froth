defmodule Froth.Analyzer.YouTubeWorker do
  use Oban.Worker, queue: :youtube, max_attempts: 20

  alias Froth.Analyzer.API
  alias Froth.Analysis
  alias Froth.Repo

  @youtube_re ~r{https?://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]+)}

  @impl true
  def perform(%Oban.Job{
        args: %{"chat_id" => chat_id, "message_id" => message_id, "text" => text}
      }) do
    url =
      case Regex.run(@youtube_re, text) do
        [url | _] -> url
        _ -> nil
      end

    if is_nil(url) do
      {:discard, "no youtube URL found"}
    else
      Froth.Analyzer.with_reactions(chat_id, message_id, fn ->
        prompt =
          "Analyze this YouTube video. Describe what it contains, the key points, who is speaking/appearing, and the overall context. Be concise but thorough."

        contents = [
          %{
            "parts" => [
              %{"text" => prompt},
              %{"fileData" => %{"fileUri" => url, "mimeType" => "video/mp4"}}
            ]
          }
        ]

        case API.gemini("gemini-3-flash-preview", contents) do
          {:ok, analysis_text} ->
            save(chat_id, message_id, analysis_text, url)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp save(chat_id, message_id, analysis_text, url) do
    %Analysis{}
    |> Analysis.changeset(%{
      type: "youtube",
      chat_id: chat_id,
      message_id: message_id,
      agent: "gemini-3-flash-preview",
      analysis_text: analysis_text,
      metadata: %{"video_url" => url},
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:type, :chat_id, :message_id, :agent],
      log: false
    )

    :ok
  end
end
