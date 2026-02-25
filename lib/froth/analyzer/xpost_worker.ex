defmodule Froth.Analyzer.XPostWorker do
  use Oban.Worker, queue: :xpost, max_attempts: 20

  alias Froth.Analyzer.API
  alias Froth.Analysis
  alias Froth.Repo

  @xpost_re ~r{https?://(?:x\.com|twitter\.com)/\w+/status/(\d+)}

  @impl true
  def perform(%Oban.Job{
        args: %{"chat_id" => chat_id, "message_id" => message_id, "text" => text}
      }) do
    url =
      case Regex.run(@xpost_re, text) do
        [url | _] -> url
        _ -> nil
      end

    if is_nil(url) do
      {:discard, "no X post URL found"}
    else
      Froth.Analyzer.with_reactions(chat_id, message_id, fn ->
        prompt =
          "Analyze this X post. Describe what it contains (text, images, video if any), the context, and key points. Be concise but thorough: #{url}"

        case API.grok(prompt, model: "grok-4-1-fast-non-reasoning") do
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
      type: "xpost",
      chat_id: chat_id,
      message_id: message_id,
      agent: "grok-4-1-fast-non-reasoning",
      analysis_text: analysis_text,
      metadata: %{"post_url" => url},
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
