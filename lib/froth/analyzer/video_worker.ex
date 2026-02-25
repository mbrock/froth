defmodule Froth.Analyzer.VideoWorker do
  use Oban.Worker, queue: :video, max_attempts: 20

  alias Froth.Analyzer.API
  alias Froth.Analysis
  alias Froth.Repo

  import Ecto.Query

  @impl true
  def perform(%Oban.Job{args: %{"chat_id" => chat_id, "message_id" => message_id}}) do
    msg =
      Repo.one(
        from(m in "telegram_messages",
          where: m.chat_id == ^chat_id and m.message_id == ^message_id,
          select: m.raw,
          limit: 1
        ),
        log: false
      )

    if is_nil(msg) do
      {:discard, "message not found"}
    else
      Froth.Analyzer.with_reactions(chat_id, message_id, fn ->
        case download_video(chat_id, message_id) do
          {:ok, video_data, mime_type, duration} ->
            analyze_and_save(chat_id, message_id, video_data, mime_type, duration)

          {:discard, _} = d ->
            d

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp download_video(chat_id, message_id) do
    {:ok, msg} =
      Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
        "@type" => "getMessage",
        "chat_id" => chat_id,
        "message_id" => message_id
      })

    case msg do
      %{"@type" => "error", "message" => m} ->
        {:discard, "getMessage: #{m}"}

      %{"content" => %{"@type" => "messageVideo"}} ->
        file_id = get_in(msg, ["content", "video", "video", "id"])
        mime = get_in(msg, ["content", "video", "mime_type"]) || "video/mp4"
        duration = get_in(msg, ["content", "video", "duration"]) || 0

        if is_nil(file_id) do
          {:discard, "no video file_id in TDLib message"}
        else
          {:ok, file} =
            Froth.Telegram.call(
              Froth.Analyzer.tdlib_session(),
              %{
                "@type" => "downloadFile",
                "file_id" => file_id,
                "priority" => 32,
                "synchronous" => true
              },
              120_000
            )

          case file do
            %{"local" => %{"path" => path}} when path != "" ->
              {:ok, File.read!(path), mime, duration}

            %{"@type" => "error", "message" => m} ->
              {:error, "downloadFile: #{m}"}

            _ ->
              {:error, "downloadFile: unexpected response #{inspect(file)}"}
          end
        end

      _ ->
        {:discard, "not a video message"}
    end
  end

  defp analyze_and_save(chat_id, message_id, video_data, mime_type, duration) do
    case upload_to_gemini(video_data, mime_type) do
      {:ok, file_uri} ->
        prompt =
          "Analyze this video. Describe what you see — people, actions, setting, text overlays, audio if any. Be observant and concise."

        case API.gemini_with_file("gemini-3-flash-preview", file_uri, mime_type, prompt) do
          {:ok, text} ->
            %Analysis{}
            |> Analysis.changeset(%{
              type: "video",
              chat_id: chat_id,
              message_id: message_id,
              agent: "gemini-3-flash-preview",
              analysis_text: text,
              metadata: %{"duration" => duration},
              generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
              inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> Repo.insert(
              on_conflict: :nothing,
              conflict_target: [:type, :chat_id, :message_id, :agent],
              log: false
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_to_gemini(data, mime_type) do
    api_key = System.get_env("GOOGLE_API_KEY")
    url = "https://generativelanguage.googleapis.com/upload/v1beta/files?key=#{api_key}"

    headers = [
      {"content-type", mime_type},
      {"x-goog-upload-command", "upload, finalize"},
      {"x-goog-upload-protocol", "raw"}
    ]

    req = Finch.build(:post, url, headers, data)

    case Finch.request(req, Froth.Finch, receive_timeout: 300_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"file" => %{"uri" => uri, "name" => name}}} ->
            wait_for_active(api_key, name, uri)

          {:ok, %{"file" => %{"uri" => uri}}} ->
            {:ok, uri}

          {:ok, other} ->
            {:error, {:unexpected_upload_response, other}}

          {:error, err} ->
            {:error, err}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:upload_http_error, status, body}}

      {:error, err} ->
        {:error, err}
    end
  end

  defp wait_for_active(api_key, name, uri, attempts \\ 0) do
    if attempts >= 30 do
      {:error, "file did not become ACTIVE after 30 attempts"}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/#{name}?key=#{api_key}"
      req = Finch.build(:get, url, [])

      case Finch.request(req, Froth.Finch, receive_timeout: 30_000) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"state" => "ACTIVE"}} ->
              {:ok, uri}

            {:ok, %{"state" => "FAILED"}} ->
              {:error, "file processing FAILED"}

            {:ok, %{"state" => _}} ->
              Process.sleep(2_000)
              wait_for_active(api_key, name, uri, attempts + 1)

            _ ->
              Process.sleep(2_000)
              wait_for_active(api_key, name, uri, attempts + 1)
          end

        _ ->
          Process.sleep(2_000)
          wait_for_active(api_key, name, uri, attempts + 1)
      end
    end
  end
end
