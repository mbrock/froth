defmodule Froth.Analyzer.PdfWorker do
  use Oban.Worker, queue: :pdf, max_attempts: 20

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
        case download_document(chat_id, message_id) do
          {:ok, data, filename, caption} ->
            analyze_and_save(chat_id, message_id, data, filename, caption)

          {:discard, _} = d ->
            d

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp download_document(chat_id, message_id) do
    {:ok, msg} =
      Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
        "@type" => "getMessage",
        "chat_id" => chat_id,
        "message_id" => message_id
      })

    case msg do
      %{"@type" => "error", "message" => m} ->
        {:discard, "getMessage: #{m}"}

      %{"content" => %{"@type" => "messageDocument", "document" => doc}} ->
        mime = doc["mime_type"] || ""

        if mime != "application/pdf" do
          {:discard, "not a PDF (#{mime})"}
        else
          filename = doc["file_name"] || "document.pdf"
          caption = get_in(msg, ["content", "caption", "text"]) || ""
          file_id = get_in(doc, ["document", "id"])

          if is_nil(file_id) do
            {:discard, "no file_id in TDLib message"}
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
                {:ok, File.read!(path), filename, caption}

              %{"@type" => "error", "message" => m} ->
                {:error, "downloadFile: #{m}"}

              _ ->
                {:error, "downloadFile: unexpected response #{inspect(file)}"}
            end
          end
        end

      _ ->
        {:discard, "not a document message"}
    end
  end

  defp analyze_and_save(chat_id, message_id, data, filename, caption) do
    prompt = """
    Analyze this PDF document "#{filename}"#{if caption != "", do: " (caption: \"#{caption}\")", else: ""}.
    Describe what it contains — text, images, structure, subject matter, style.
    Be observant and concise.
    """

    case API.claude(
           [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "document",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "application/pdf",
                     "data" => Base.encode64(data)
                   }
                 },
                 %{"type" => "text", "text" => prompt}
               ]
             }
           ],
           model: "claude-sonnet-4-6"
         ) do
      {:ok, analysis_text} ->
        %Analysis{}
        |> Analysis.changeset(%{
          type: "pdf",
          chat_id: chat_id,
          message_id: message_id,
          agent: "claude-sonnet-4-6",
          analysis_text: analysis_text,
          metadata: %{filename: filename},
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
