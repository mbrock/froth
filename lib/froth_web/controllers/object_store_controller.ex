defmodule FrothWeb.ObjectStoreController do
  use FrothWeb, :controller

  alias Froth.Cast.Parser
  alias Froth.ObjectStore
  @asciicast_content_types ["application/x-asciicast", "application/json"]

  def show(conn, %{"key" => segments}) when is_list(segments) do
    with {:ok, key} <- normalize_segments(segments) do
      case ObjectStore.mode() do
        :local ->
          send_local_object(conn, key)

        :proxy ->
          send_proxy_object(conn, key)
      end
    else
      {:error, _reason} ->
        send_resp(conn, 404, "not found")
    end
  end

  def create(conn, _params) do
    with :ok <- authorize_write(conn),
         {:ok, body, conn} <- read_full_body(conn),
         content_type = request_content_type(conn),
         {:ok, stored} <-
           ObjectStore.put_blob(body,
             content_type: content_type
           ) do
      payload =
        %{
          key: stored.key,
          url: public_object_url(conn, stored.key),
          sha256: stored.sha256,
          content_type: stored.content_type,
          content_length: stored.content_length
        }
        |> maybe_put_asciicast_html_url(conn, body, stored.sha256, content_type)

      conn
      |> put_resp_header("location", public_object_url(conn, stored.key))
      |> put_status(:created)
      |> json(payload)
    else
      {:error, :unauthorized} ->
        send_resp(conn, 401, "unauthorized")

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: inspect(reason, printable_limit: :infinity)})
    end
  end

  def put(conn, %{"key" => segments}) when is_list(segments) do
    with :ok <- authorize_write(conn),
         {:ok, key} <- normalize_segments(segments),
         {:ok, body, conn} <- read_full_body(conn),
         {:ok, _stored} <-
           ObjectStore.put_bytes(key, body, content_type: request_content_type(conn)) do
      json(conn, %{key: key, url: public_object_url(conn, key)})
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

  defp send_local_object(conn, key) do
    case ObjectStore.locate(key) do
      {:ok, %{path: path, metadata: metadata}} ->
        conn
        |> put_immutable_headers(metadata.sha256)
        |> put_raw_content_type(metadata.content_type)
        |> send_file(200, path)

      {:error, _reason} ->
        send_resp(conn, 404, "not found")
    end
  end

  defp send_proxy_object(conn, key) do
    case ObjectStore.get(key) do
      {:ok, %{body: body, metadata: metadata}} ->
        conn
        |> put_immutable_headers(metadata.sha256)
        |> put_raw_content_type(metadata.content_type)
        |> send_resp(200, body)

      {:error, _reason} ->
        send_resp(conn, 404, "not found")
    end
  end

  defp normalize_segments(segments) do
    segments
    |> Enum.join("/")
    |> ObjectStore.normalize_key()
  end

  defp maybe_put_asciicast_html_url(payload, conn, body, sha256, content_type) do
    if content_type in @asciicast_content_types do
      case Parser.parse(body) do
        {:ok, _recording} ->
          Map.put(
            payload,
            :asciicast_html_url,
            public_asciicast_url(conn, sha256)
          )

        {:error, _reason} ->
          payload
      end
    else
      payload
    end
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

  defp request_content_type(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      nil -> "application/octet-stream"
      content_type -> String.split(content_type, ";", parts: 2) |> hd()
    end
  end

  defp put_raw_content_type(conn, content_type) do
    put_resp_header(conn, "content-type", content_type || "application/octet-stream")
  end

  defp public_object_url(conn, key) do
    case forwarded_origin(conn) do
      nil -> ObjectStore.public_url(key)
      origin -> origin <> "/froth/objects/" <> key
    end
  end

  defp public_asciicast_url(conn, sha256) do
    case forwarded_origin(conn) do
      nil -> url(conn, ~p"/froth/asciicasts/#{sha256}")
      origin -> origin <> "/froth/asciicasts/" <> sha256
    end
  end

  defp forwarded_origin(conn) do
    with host when is_binary(host) and host != "" <- forwarded_header(conn, "x-forwarded-host"),
         scheme <- forwarded_header(conn, "x-forwarded-proto") || "https" do
      forwarded_origin_url(scheme, host, forwarded_header(conn, "x-forwarded-port"))
    else
      _ -> nil
    end
  end

  defp forwarded_header(conn, name) do
    conn
    |> get_req_header(name)
    |> List.first()
    |> case do
      nil ->
        nil

      value ->
        value
        |> String.split(",", parts: 2)
        |> hd()
        |> String.trim()
        |> case do
          "" -> nil
          header_value -> header_value
        end
    end
  end

  defp forwarded_origin_url(scheme, host, port) do
    cond do
      String.contains?(host, ":") ->
        "#{scheme}://#{host}"

      port in [nil, "", default_port(scheme)] ->
        "#{scheme}://#{host}"

      true ->
        "#{scheme}://#{host}:#{port}"
    end
  end

  defp default_port("https"), do: "443"
  defp default_port("http"), do: "80"
  defp default_port(_scheme), do: nil

  defp put_immutable_headers(conn, sha256) do
    conn
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> maybe_put_etag(sha256)
  end

  defp maybe_put_etag(conn, nil), do: conn
  defp maybe_put_etag(conn, sha256), do: put_resp_header(conn, "etag", ~s|"sha256-#{sha256}"|)

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
