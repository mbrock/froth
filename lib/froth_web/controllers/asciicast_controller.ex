defmodule FrothWeb.AsciicastController do
  use FrothWeb, :controller

  alias Froth.Cast
  alias Froth.Cast.Parser
  alias Froth.ObjectStore

  def show(conn, %{"sha256" => sha256}) do
    with {:ok, key} <- ObjectStore.content_address_key("sha256", sha256),
         {:ok, %{body: body, metadata: metadata}} <- ObjectStore.get(key),
         {:ok, recording} <- Parser.parse(body),
         {:ok, html} <- Cast.render_html(recording, title: cast_title(recording.title, sha256)) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> maybe_put_etag(metadata.sha256)
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    else
      {:error, :object_not_found} ->
        send_resp(conn, 404, "not found")

      {:error, :invalid_digest} ->
        send_resp(conn, 404, "not found")

      {:error, :unsupported_algorithm} ->
        send_resp(conn, 404, "not found")

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(415, "object is not an asciicast")
    end
  end

  defp cast_title(title, _sha256) when is_binary(title) and title != "", do: title
  defp cast_title(_title, sha256), do: "Asciicast #{String.slice(sha256, 0, 12)}"

  defp maybe_put_etag(conn, nil), do: conn
  defp maybe_put_etag(conn, sha256), do: put_resp_header(conn, "etag", ~s|"sha256-#{sha256}"|)
end
