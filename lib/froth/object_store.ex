defmodule Froth.ObjectStore do
  @moduledoc """
  Small shared object store abstraction for render artifacts and other blobs.

  In `:local` mode objects are written directly under a configured root
  directory. In `:proxy` mode writes and reads go over HTTP to a remote Froth
  node exposing the object store routes.
  """

  @default_content_type "application/octet-stream"

  def put_file(key, src_path, opts \\ [])
      when is_binary(key) and is_binary(src_path) and is_list(opts) do
    with {:ok, normalized_key} <- normalize_key(key),
         {:ok, body} <- File.read(src_path) do
      put_bytes(
        normalized_key,
        body,
        Keyword.put_new(opts, :content_type, MIME.from_path(src_path) || @default_content_type)
      )
    end
  end

  def put_bytes(key, body, opts \\ [])
      when is_binary(key) and is_binary(body) and is_list(opts) do
    with {:ok, normalized_key} <- normalize_key(key) do
      content_type = Keyword.get(opts, :content_type, @default_content_type)

      case mode() do
        :local ->
          path = local_path!(normalized_key)

          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- File.write(path, body) do
            {:ok, %{key: normalized_key, path: path, url: public_url(normalized_key)}}
          end

        :proxy ->
          req_headers =
            [{"content-type", content_type}]
            |> maybe_put_write_token()

          case Req.put(internal_url(normalized_key), headers: req_headers, body: body) do
            {:ok, %{status: status}} when status in 200..299 ->
              {:ok, %{key: normalized_key, url: public_url(normalized_key)}}

            {:ok, %{status: status, body: response_body}} ->
              {:error, {:object_store_put_failed, status, response_body}}

            {:error, reason} ->
              {:error, reason}
          end
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

  defp local_path!(normalized_key) do
    normalized_key
    |> String.split("/", trim: true)
    |> Enum.reduce(root_dir(), &Path.join(&2, &1))
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
end
