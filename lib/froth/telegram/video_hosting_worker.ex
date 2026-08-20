defmodule Froth.Telegram.VideoHostingWorker do
  use Oban.Worker,
    queue: :video,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Froth.Telegram.VideoHosting

  @download_timeout :timer.minutes(25)

  @impl true
  def perform(%Oban.Job{
        args: %{"chat_id" => chat_id, "message_id" => message_id}
      }) do
    case VideoHosting.resume(chat_id, message_id) do
      :ok ->
        :ok

      :not_hosted ->
        download_and_host(chat_id, message_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_and_host(chat_id, message_id) do
    session_id = Froth.Analyzer.tdlib_session()

    with {:ok, message} <-
           Froth.Telegram.call(session_id, %{
             "@type" => "getMessage",
             "chat_id" => chat_id,
             "message_id" => message_id
           }),
         {:ok, file_id} <- video_file_id(message),
         {:ok, file} <-
           Froth.Telegram.call(
             session_id,
             %{
               "@type" => "downloadFile",
               "file_id" => file_id,
               "priority" => 32,
               "synchronous" => true
             },
             @download_timeout
           ),
         {:ok, path} <- local_path(file) do
      VideoHosting.maybe_host(message, path)
    end
  end

  defp video_file_id(%{"content" => %{"@type" => "messageVideo"}} = message) do
    case get_in(message, ["content", "video", "video", "id"]) do
      id when is_integer(id) -> {:ok, id}
      _ -> {:discard, "video has no downloadable file"}
    end
  end

  defp video_file_id(%{
         "content" => %{
           "@type" => "messageDocument",
           "document" => %{"mime_type" => "video/" <> _subtype} = document
         }
       }) do
    case get_in(document, ["document", "id"]) do
      id when is_integer(id) -> {:ok, id}
      _ -> {:discard, "video document has no downloadable file"}
    end
  end

  defp video_file_id(%{"@type" => "error", "message" => message}),
    do: {:discard, "getMessage: #{message}"}

  defp video_file_id(_message), do: {:discard, "not a video message"}

  defp local_path(%{"local" => %{"path" => path}})
       when is_binary(path) and path != "",
       do: {:ok, path}

  defp local_path(%{"@type" => "error", "message" => message}),
    do: {:error, "downloadFile: #{message}"}

  defp local_path(file),
    do: {:error, "downloadFile: unexpected response #{inspect(file)}"}
end
