defmodule FrothWeb.MediaController do
  use FrothWeb, :controller

  def show(conn, %{"chat_id" => chat_id_str, "message_id" => message_id_str}) do
    chat_id = String.to_integer(chat_id_str)
    message_id = String.to_integer(message_id_str)

    case Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
           "@type" => "getMessage",
           "chat_id" => chat_id,
           "message_id" => message_id
         }) do
      {:ok, %{"content" => %{"@type" => "messagePhoto"} = content}} ->
        sizes = get_in(content, ["photo", "sizes"]) || []

        largest =
          Enum.max_by(sizes, fn s -> (s["width"] || 0) * (s["height"] || 0) end, fn -> nil end)

        serve_file(conn, get_in(largest, ["photo", "id"]))

      {:ok, %{"content" => %{"@type" => "messageDocument", "document" => doc}}} ->
        serve_file(
          conn,
          get_in(doc, ["document", "id"]),
          doc["mime_type"] || "application/octet-stream"
        )

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  defp serve_file(conn, file_id, mime \\ "image/jpeg")

  defp serve_file(conn, nil, _mime) do
    send_resp(conn, 404, "no file")
  end

  defp serve_file(conn, file_id, mime) do
    case Froth.Telegram.call(Froth.Analyzer.tdlib_session(), %{
           "@type" => "downloadFile",
           "file_id" => file_id,
           "priority" => 32,
           "synchronous" => true
         }) do
      {:ok, %{"local" => %{"path" => path}}} when path != "" ->
        mime = guess_mime(path, mime)

        conn
        |> put_resp_header("content-type", mime)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_file(200, path)

      _ ->
        send_resp(conn, 404, "download failed")
    end
  end

  defp guess_mime(path, default) do
    cond do
      String.ends_with?(path, ".png") -> "image/png"
      String.ends_with?(path, ".jpg") or String.ends_with?(path, ".jpeg") -> "image/jpeg"
      String.ends_with?(path, ".webp") -> "image/webp"
      String.ends_with?(path, ".pdf") -> "application/pdf"
      true -> default
    end
  end
end
