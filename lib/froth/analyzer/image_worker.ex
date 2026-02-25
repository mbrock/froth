defmodule Froth.Analyzer.ImageWorker do
  use Oban.Worker, queue: :image, max_attempts: 20

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
        case download_photo(chat_id, message_id) do
          {:ok, image_data, mime_type, caption} ->
            analyze_and_save(chat_id, message_id, image_data, mime_type, caption)

          {:discard, _} = d ->
            d

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp download_photo(chat_id, message_id) do
    {:ok, msg} =
      Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
        "@type" => "getMessage",
        "chat_id" => chat_id,
        "message_id" => message_id
      })

    case msg do
      %{"@type" => "error", "message" => m} ->
        {:discard, "getMessage: #{m}"}

      %{"content" => %{"@type" => "messagePhoto"}} ->
        sizes = get_in(msg, ["content", "photo", "sizes"]) || []
        caption = get_in(msg, ["content", "caption", "text"]) || ""

        largest =
          Enum.max_by(
            sizes,
            fn s ->
              (s["width"] || 0) * (s["height"] || 0)
            end,
            fn -> nil end
          )

        file_id = get_in(largest, ["photo", "id"])

        if is_nil(file_id) do
          {:discard, "no photo file_id in TDLib message"}
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
              data = File.read!(path)
              mime = if String.ends_with?(path, ".png"), do: "image/png", else: "image/jpeg"
              {:ok, data, mime, caption}

            %{"@type" => "error", "message" => m} ->
              {:error, "downloadFile: #{m}"}

            _ ->
              {:error, "downloadFile: unexpected response #{inspect(file)}"}
          end
        end

      _ ->
        {:discard, "not a photo message"}
    end
  end

  defp analyze_and_save(chat_id, message_id, image_data, mime_type, caption) do
    prompt = """
    Analyze this image from a Telegram message#{if caption != "", do: " (caption: \"#{caption}\")", else: ""}.
    Describe what you see — people, objects, text, style, mood, and anything interesting.
    Be observant and concise.
    """

    case API.claude(
           [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => mime_type,
                     "data" => Base.encode64(image_data)
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
          type: "image",
          chat_id: chat_id,
          message_id: message_id,
          agent: "claude-sonnet-4-6",
          analysis_text: analysis_text,
          metadata: %{},
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
