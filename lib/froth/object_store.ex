defmodule Froth.ObjectStore do
  @moduledoc """
  Small shared object store abstraction for render artifacts and other blobs.

  In `:local` mode objects are written directly under a configured root
  directory. In `:proxy` mode writes and reads go over HTTP to a remote Froth
  node exposing the object store routes.
  """

  @default_content_type "application/octet-stream"
  @sha256_algorithm "sha256"

  def put_file(key, src_path, opts \\ [])
      when is_binary(key) and is_binary(src_path) and is_list(opts) do
    with {:ok, normalized_key} <- normalize_key(key),
         {:ok, body} <- File.read(src_path) do
      put_bytes(
        normalized_key,
        body,
        Keyword.put_new(
          opts,
          :content_type,
          MIME.from_path(src_path) || @default_content_type
        )
      )
    end
  end

  def put_blob(body, opts \\ []) when is_binary(body) and is_list(opts) do
    sha256 = sha256_hex(body)

    with {:ok, key} <- content_address_key(@sha256_algorithm, sha256),
         {:ok, stored} <-
           put_bytes(key, body, Keyword.put(opts, :sha256, sha256)) do
      {:ok, Map.put(stored, :sha256, sha256)}
    end
  end

  def put_bytes(key, body, opts \\ [])
      when is_binary(key) and is_binary(body) and is_list(opts) do
    with {:ok, normalized_key} <- normalize_key(key) do
      content_type = Keyword.get(opts, :content_type, @default_content_type)
      metadata = build_metadata(normalized_key, body, content_type, opts)

      case mode() do
        :local ->
          path = local_path!(normalized_key)

          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, body),
               :ok <- write_metadata(normalized_key, metadata) do
            {:ok,
             %{
               key: normalized_key,
               path: path,
               url: public_url(normalized_key),
               content_type: metadata.content_type,
               content_length: metadata.content_length
             }}
          end

        :proxy ->
          req_headers =
            [{"content-type", content_type}]
            |> maybe_put_write_token()

          case Req.put(internal_url(normalized_key),
                 headers: req_headers,
                 body: body
               ) do
            {:ok, %{status: status}} when status in 200..299 ->
              {:ok,
               %{
                 key: normalized_key,
                 url: public_url(normalized_key),
                 content_type: metadata.content_type,
                 content_length: metadata.content_length
               }}

            {:ok, %{status: status, body: response_body}} ->
              {:error, {:object_store_put_failed, status, response_body}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  def get(key) when is_binary(key) do
    with {:ok, normalized_key} <- normalize_key(key) do
      case mode() do
        :local -> get_local(normalized_key)
        :proxy -> get_proxy(normalized_key)
      end
    end
  end

  def locate(key) when is_binary(key) do
    with {:ok, normalized_key} <- normalize_key(key) do
      path = local_path!(normalized_key)

      if File.exists?(path) do
        {:ok,
         %{
           key: normalized_key,
           path: path,
           metadata: read_local_metadata(normalized_key, path)
         }}
      else
        {:error, :object_not_found}
      end
    end
  end

  def fetch(key, destination_path, opts \\ [])
      when is_binary(key) and is_binary(destination_path) and is_list(opts) do
    with {:ok, normalized_key} <- normalize_key(key) do
      case mode() do
        :local ->
          path = local_path!(normalized_key)

          if File.exists?(path) do
            with :ok <- File.mkdir_p(Path.dirname(destination_path)),
                 :ok <- File.cp(path, destination_path) do
              {:ok, destination_path}
            end
          else
            {:error, :object_not_found}
          end

        :proxy ->
          fetch_url(internal_url(normalized_key), destination_path, opts)
      end
    end
  end

  def fetch_url(url, destination_path, _opts \\ [])
      when is_binary(url) and is_binary(destination_path) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        with :ok <- File.mkdir_p(Path.dirname(destination_path)),
             :ok <- File.write(destination_path, body) do
          {:ok, destination_path}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:object_store_get_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def public_url(key) when is_binary(key) do
    base =
      config_value(:public_base) ||
        String.trim_trailing(FrothWeb.Endpoint.url(), "/") <> "/froth/objects"

    String.trim_trailing(base, "/") <> "/" <> key
  end

  def local_path(key) when is_binary(key) do
    with {:ok, normalized_key} <- normalize_key(key) do
      {:ok, local_path!(normalized_key)}
    end
  end

  def root_dir do
    config_value(:root_dir, Path.expand("tmp/object-store"))
    |> Path.expand()
  end

  def mode do
    case config_value(:mode, :local) do
      :proxy -> :proxy
      "proxy" -> :proxy
      _ -> :local
    end
  end

  def normalize_key(key) when is_binary(key) do
    segments =
      key
      |> String.split("/", trim: true)
      |> Enum.reject(&(&1 == ""))

    cond do
      segments == [] ->
        {:error, :invalid_key}

      Enum.any?(segments, &invalid_segment?/1) ->
        {:error, :invalid_key}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  def content_address_key(algorithm, digest)
      when is_binary(algorithm) and is_binary(digest) do
    normalized_algorithm = String.trim(algorithm) |> String.downcase()
    normalized_digest = String.trim(digest) |> String.downcase()

    cond do
      normalized_algorithm != @sha256_algorithm ->
        {:error, :unsupported_algorithm}

      not valid_sha256_digest?(normalized_digest) ->
        {:error, :invalid_digest}

      true ->
        {:ok, "#{@sha256_algorithm}/#{normalized_digest}"}
    end
  end

  defp local_path!(normalized_key) do
    normalized_key
    |> String.split("/", trim: true)
    |> Enum.reduce(root_dir(), &Path.join(&2, &1))
  end

  defp get_local(normalized_key) do
    with {:ok, located} <- locate(normalized_key),
         {:ok, body} <- File.read(located.path) do
      {:ok,
       %{
         key: normalized_key,
         path: located.path,
         body: body,
         metadata:
           Map.put_new(located.metadata, :content_length, byte_size(body))
       }}
    end
  end

  defp get_proxy(normalized_key) do
    case Req.get(internal_url(normalized_key), decode_body: false) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        metadata =
          %{
            content_type:
              header_value(headers, "content-type") ||
                MIME.from_path(normalized_key) || @default_content_type,
            content_length: byte_size(body),
            sha256: sha256_from_key(normalized_key)
          }

        {:ok, %{key: normalized_key, body: body, metadata: metadata}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:object_store_get_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_metadata(normalized_key, body, content_type, opts) do
    %{
      key: normalized_key,
      content_type: content_type,
      content_length: byte_size(body),
      sha256: Keyword.get(opts, :sha256, sha256_hex(body))
    }
  end

  defp write_metadata(normalized_key, metadata) do
    path = metadata_path(normalized_key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(metadata)) do
      :ok
    end
  end

  defp read_local_metadata(normalized_key, path) do
    case File.read(metadata_path(normalized_key)) do
      {:ok, metadata_json} ->
        case Jason.decode(metadata_json) do
          {:ok, metadata} ->
            normalize_metadata(metadata, normalized_key, path)

          {:error, _reason} ->
            fallback_metadata(normalized_key, path)
        end

      {:error, _reason} ->
        fallback_metadata(normalized_key, path)
    end
  end

  defp normalize_metadata(metadata, normalized_key, path)
       when is_map(metadata) do
    %{
      key: normalized_key,
      content_type:
        metadata["content_type"] || metadata["content-type"] ||
          metadata[:content_type] ||
          MIME.from_path(path || normalized_key) || @default_content_type,
      content_length:
        metadata["content_length"] || metadata["content-length"] ||
          metadata[:content_length],
      sha256:
        metadata["sha256"] || metadata[:sha256] ||
          sha256_from_key(normalized_key)
    }
  end

  defp fallback_metadata(normalized_key, path) do
    %{
      key: normalized_key,
      content_type:
        MIME.from_path(path || normalized_key) || @default_content_type,
      content_length: nil,
      sha256: sha256_from_key(normalized_key)
    }
  end

  defp metadata_path(normalized_key) do
    Path.join([
      metadata_root_dir() | String.split(normalized_key, "/", trim: true)
    ]) <> ".json"
  end

  defp metadata_root_dir do
    config_value(:metadata_root_dir, root_dir() <> "-meta")
    |> Path.expand()
  end

  defp invalid_segment?(segment) do
    segment in [".", ".."] or String.contains?(segment, <<0>>)
  end

  defp internal_url(key) do
    base =
      config_value(:internal_base) ||
        config_value(:public_base) ||
        String.trim_trailing(FrothWeb.Endpoint.url(), "/") <> "/froth/objects"

    String.trim_trailing(base, "/") <> "/" <> key
  end

  defp maybe_put_write_token(headers) do
    case config_value(:write_token) do
      token when is_binary(token) and token != "" ->
        [{"x-froth-object-store-token", token} | headers]

      _ ->
        headers
    end
  end

  defp config_value(key, default \\ nil) do
    Application.get_env(:froth, __MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp header_value(headers, key) when is_list(headers) and is_binary(key) do
    needle = String.downcase(key)

    Enum.find_value(headers, fn
      {header_key, value} when is_binary(header_key) and is_binary(value) ->
        if String.downcase(header_key) == needle, do: value

      _other ->
        nil
    end)
  end

  defp sha256_from_key(normalized_key) do
    case String.split(normalized_key, "/", parts: 2) do
      [@sha256_algorithm, digest] ->
        if valid_sha256_digest?(digest), do: digest

      _ ->
        nil
    end
  end

  defp sha256_hex(body) when is_binary(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp valid_sha256_digest?(digest) when is_binary(digest) do
    String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
  end
end
