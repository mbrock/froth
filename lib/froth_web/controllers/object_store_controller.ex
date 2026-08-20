defmodule FrothWeb.ObjectStoreController do
  use FrothWeb, :controller

  alias Froth.ObjectStore

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
      _ = content_type

      payload =
        %{
          key: stored.key,
          url: public_object_url(conn, stored.key),
          sha256: stored.sha256,
          content_type: stored.content_type,
          content_length: stored.content_length
        }

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
         {:ok, upload_path, conn} <- stream_body_to_temporary_file(conn),
         {:ok, _stored} <- store_upload(key, upload_path, conn) do
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
        stat = File.stat!(path)

        conn =
          conn
          |> put_immutable_headers(metadata.sha256)
          |> put_raw_content_type(metadata.content_type)
          |> put_resp_header("accept-ranges", "bytes")

        send_local_range(conn, path, stat.size)

      {:error, _reason} ->
        send_resp(conn, 404, "not found")
    end
  end

  defp send_proxy_object(conn, key) do
    request_headers =
      case List.first(get_req_header(conn, "range")) do
        range when is_binary(range) -> [{"range", range}]
        nil -> []
      end

    case ObjectStore.proxy_get(key, request_headers) do
      {:ok, %{status: status, body: body, headers: headers}}
      when status in [200, 206] ->
        conn
        |> put_immutable_headers(proxy_etag_sha(headers))
        |> put_raw_content_type(proxy_header(headers, "content-type"))
        |> copy_proxy_header(headers, "accept-ranges")
        |> copy_proxy_header(headers, "content-range")
        |> copy_proxy_header(headers, "content-length")
        |> send_resp(status, body)

      {:ok, %{status: 416, headers: headers}} ->
        conn
        |> copy_proxy_header(headers, "accept-ranges")
        |> copy_proxy_header(headers, "content-range")
        |> send_resp(416, "")

      {:error, _reason} ->
        send_resp(conn, 404, "not found")

      _response ->
        send_resp(conn, 404, "not found")
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
    put_resp_header(
      conn,
      "content-type",
      content_type || "application/octet-stream"
    )
  end

  defp public_object_url(conn, key) do
    case forwarded_origin(conn) do
      nil -> ObjectStore.public_url(key)
      origin -> origin <> "/froth/objects/" <> key
    end
  end

  defp forwarded_origin(conn) do
    with host when is_binary(host) and host != "" <-
           forwarded_header(conn, "x-forwarded-host"),
         scheme <- forwarded_header(conn, "x-forwarded-proto") || "https" do
      forwarded_origin_url(
        scheme,
        host,
        forwarded_header(conn, "x-forwarded-port")
      )
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

  defp send_local_range(conn, path, size) do
    case parse_range(List.first(get_req_header(conn, "range")), size) do
      :all ->
        send_file(conn, 200, path)

      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> put_resp_header(
          "content-length",
          Integer.to_string(last - first + 1)
        )
        |> send_file(206, path, first, last - first + 1)

      :invalid ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  defp parse_range(nil, _size), do: :all

  defp parse_range("bytes=" <> value, size) when size > 0 do
    case String.split(value, ",", trim: true) do
      [single] -> parse_single_range(String.trim(single), size)
      _ -> :invalid
    end
  end

  defp parse_range(_range, _size), do: :invalid

  defp parse_single_range("-" <> suffix, size) do
    case Integer.parse(suffix) do
      {length, ""} when length > 0 ->
        first = max(size - length, 0)
        {:ok, first, size - 1}

      _ ->
        :invalid
    end
  end

  defp parse_single_range(value, size) do
    case String.split(value, "-", parts: 2) do
      [first, ""] -> range_from(first, size - 1, size)
      [first, last] -> range_from(first, last, size)
      _ -> :invalid
    end
  end

  defp range_from(first, last, size) when is_binary(last) do
    with {parsed_last, ""} <- Integer.parse(last) do
      range_from(first, min(parsed_last, size - 1), size)
    else
      _ -> :invalid
    end
  end

  defp range_from(first, last, size) when is_integer(last) do
    with {parsed_first, ""} <- Integer.parse(first),
         true <-
           parsed_first >= 0 and parsed_first < size and last >= parsed_first do
      {:ok, parsed_first, last}
    else
      _ -> :invalid
    end
  end

  defp maybe_put_etag(conn, nil), do: conn

  defp maybe_put_etag(conn, sha256),
    do: put_resp_header(conn, "etag", ~s|"sha256-#{sha256}"|)

  defp proxy_etag_sha(headers) do
    case proxy_header(headers, "etag") do
      "\"sha256-" <> rest -> String.trim_trailing(rest, "\"")
      _ -> nil
    end
  end

  defp copy_proxy_header(conn, headers, name) do
    case proxy_header(headers, name) do
      nil -> conn
      value -> put_resp_header(conn, name, value)
    end
  end

  defp proxy_header(headers, name) when is_map(headers) do
    headers
    |> Map.get(name, [])
    |> List.first()
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

  defp stream_body_to_temporary_file(conn) do
    path =
      Path.join(
        System.tmp_dir!(),
        "froth-object-upload-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} -> stream_body(conn, path, io)
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_body(conn, path, io) do
    case read_body(conn) do
      {:ok, chunk, conn} ->
        result = IO.binwrite(io, chunk)
        File.close(io)

        case result do
          :ok ->
            {:ok, path, conn}

          {:error, reason} ->
            File.rm(path)
            {:error, reason}
        end

      {:more, chunk, conn} ->
        case IO.binwrite(io, chunk) do
          :ok ->
            stream_body(conn, path, io)

          {:error, reason} ->
            File.close(io)
            File.rm(path)
            {:error, reason}
        end

      {:error, reason} ->
        File.close(io)
        File.rm(path)
        {:error, reason}
    end
  end

  defp store_upload(key, upload_path, conn) do
    result =
      ObjectStore.put_file(key, upload_path,
        content_type: request_content_type(conn)
      )

    File.rm(upload_path)
    result
  end
end
