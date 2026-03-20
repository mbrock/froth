defmodule FrothWeb.ObjectStoreController do
  use FrothWeb, :controller

  alias Froth.ObjectStore

  def show(conn, %{"key" => segments}) when is_list(segments) do
    with {:ok, key} <- normalize_segments(segments),
         {:ok, path} <- ObjectStore.local_path(key),
         true <- File.exists?(path) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_content_type(MIME.from_path(path) || "application/octet-stream")
      |> send_file(200, path)
    else
      false ->
        send_resp(conn, 404, "not found")

      {:error, _reason} ->
        send_resp(conn, 404, "not found")
    end
  end

  def put(conn, %{"key" => segments}) when is_list(segments) do
    with :ok <- authorize_write(conn),
         {:ok, key} <- normalize_segments(segments),
         {:ok, body, conn} <- read_full_body(conn),
         {:ok, %{url: url}} <-
           ObjectStore.put_bytes(key, body,
             content_type:
               List.first(get_req_header(conn, "content-type")) || "application/octet-stream"
           ) do
      json(conn, %{key: key, url: url})
    else
      {:error, :unauthorized} ->
        send_resp(conn, 401, "unauthorized")

      {:error, :invalid_key} ->
        send_resp(conn, 400, "invalid key")

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: inspect(reason, printable_limit: :infinity)})
    end
  end

  defp normalize_segments(segments) do
    segments
    |> Enum.join("/")
    |> ObjectStore.normalize_key()
  end

  defp authorize_write(conn) do
    configured = Application.get_env(:froth, ObjectStore, [])[:write_token]
    provided = List.first(get_req_header(conn, "x-froth-object-store-token"))

    cond do
      not is_binary(configured) or configured == "" ->
        :ok

      provided == configured ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, [chunk | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end
end
