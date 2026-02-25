defmodule Froth.Analyzer.VoiceWorker do
  use Oban.Worker, queue: :voice, max_attempts: 20

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
        case download_voice(chat_id, message_id) do
          {:ok, audio_data, mime_type, duration} ->
            analyze_and_save(chat_id, message_id, audio_data, mime_type, duration)

          {:discard, _} = d ->
            d

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp download_voice(chat_id, message_id) do
    {:ok, msg} =
      Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
        "@type" => "getMessage",
        "chat_id" => chat_id,
        "message_id" => message_id
      })

    case msg do
      %{"@type" => "error", "message" => m} ->
        {:discard, "getMessage: #{m}"}

      %{"content" => %{"@type" => type}} when type in ["messageVoiceNote", "messageAudio"] ->
        {file_id, mime, duration} = extract_voice_info(msg)

        if is_nil(file_id) do
          {:discard, "no audio file_id in TDLib message"}
        else
          {:ok, file} =
            Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
              "@type" => "downloadFile",
              "file_id" => file_id,
              "priority" => 32,
              "synchronous" => true
            })

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
        {:discard, "not a voice/audio message"}
    end
  end

  defp extract_voice_info(raw) do
    case raw["content"]["@type"] do
      "messageVoiceNote" ->
        {
          get_in(raw, ["content", "voice_note", "voice", "id"]),
          get_in(raw, ["content", "voice_note", "mime_type"]) || "audio/ogg",
          get_in(raw, ["content", "voice_note", "duration"]) || 0
        }

      "messageAudio" ->
        {
          get_in(raw, ["content", "audio", "audio", "id"]),
          get_in(raw, ["content", "audio", "mime_type"]) || "audio/mpeg",
          get_in(raw, ["content", "audio", "duration"]) || 0
        }

      _ ->
        {nil, "audio/ogg", 0}
    end
  end

  defp analyze_and_save(chat_id, message_id, audio_data, mime_type, duration) do
    prompt =
      "Transcribe this voice message and briefly describe the tone/context. Return the transcription first, then the analysis."

    case API.gemini_with_inline("gemini-3-flash-preview", audio_data, mime_type, prompt) do
      {:ok, text} ->
        %Analysis{}
        |> Analysis.changeset(%{
          type: "voice",
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
  end
end
