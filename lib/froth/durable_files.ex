defmodule Froth.DurableFiles do
  @moduledoc false

  @default_files_base_url "https://less.rest/files"
  @files_dir Path.expand("../priv/static/files", __DIR__)

  @spec persist(binary(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def persist(file_data, media_type, filename)
      when is_binary(file_data) and is_binary(media_type) and is_binary(filename) do
    with :ok <- File.mkdir_p(@files_dir),
         {:ok, basename} <- durable_filename(file_data, media_type, filename),
         local_path <- Path.join(@files_dir, basename),
         :ok <- write_if_missing_or_different(local_path, file_data) do
      {:ok,
       %{
         "local_path" => local_path,
         "public_url" => public_url_for(basename),
         "media_type" => normalize_media_type(media_type),
         "size_bytes" => byte_size(file_data),
         "filename" => filename
       }}
    else
      {:error, reason} ->
        {:error, "durable file write failed: #{inspect(reason)}"}
    end
  end

  @spec media_type_from_filename(String.t() | any()) :: String.t() | nil
  def media_type_from_filename(filename) when is_binary(filename) do
    filename
    |> String.downcase()
    |> Path.extname()
    |> media_type_from_extension()
  end

  def media_type_from_filename(_), do: nil

  @spec media_type_from_path(String.t() | any()) :: String.t() | nil
  def media_type_from_path(path) when is_binary(path) do
    path
    |> String.downcase()
    |> Path.extname()
    |> media_type_from_extension()
  end

  def media_type_from_path(_), do: nil

  @spec extension_from_media_type(String.t() | any()) :: String.t() | nil
  def extension_from_media_type(media_type) when is_binary(media_type) do
    normalized_media_type = normalize_media_type(media_type)

    case normalized_media_type do
      "application/pdf" -> ".pdf"
      "application/zip" -> ".zip"
      "application/x-tgsticker" -> ".tgs"
      "image/jpeg" -> ".jpg"
      "image/png" -> ".png"
      "image/webp" -> ".webp"
      "image/gif" -> ".gif"
      "image/bmp" -> ".bmp"
      "image/tiff" -> ".tiff"
      "image/heic" -> ".heic"
      "image/heif" -> ".heif"
      "video/mp4" -> ".mp4"
      "video/quicktime" -> ".mov"
      "video/webm" -> ".webm"
      "audio/mpeg" -> ".mp3"
      "audio/mp4" -> ".m4a"
      "audio/x-m4a" -> ".m4a"
      "audio/aac" -> ".aac"
      "audio/wav" -> ".wav"
      "audio/x-wav" -> ".wav"
      "audio/ogg" -> ".ogg"
      "audio/flac" -> ".flac"
      _ -> fallback_extension_from_mime(normalized_media_type)
    end
  end

  def extension_from_media_type(_), do: nil

  @spec extension_from_filename(String.t() | any()) :: String.t() | nil
  def extension_from_filename(filename) when is_binary(filename) do
    case filename |> String.trim() |> Path.extname() do
      "" -> nil
      extension -> extension
    end
  end

  def extension_from_filename(_), do: nil

  defp durable_filename(file_data, media_type, filename)
       when is_binary(file_data) and is_binary(media_type) and is_binary(filename) do
    hash =
      :crypto.hash(:sha256, file_data)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    extension =
      extension_from_media_type(media_type) ||
        extension_from_filename(filename) ||
        ".bin"

    {:ok, hash <> extension}
  end

  defp write_if_missing_or_different(local_path, file_data)
       when is_binary(local_path) and is_binary(file_data) do
    size_bytes = byte_size(file_data)

    case File.stat(local_path) do
      {:ok, %File.Stat{size: ^size_bytes}} ->
        :ok

      {:ok, %File.Stat{}} ->
        File.write(local_path, file_data)

      {:error, :enoent} ->
        File.write(local_path, file_data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp public_url_for(basename) when is_binary(basename) do
    base_url =
      :froth
      |> Application.get_env(:files_base_url, @default_files_base_url)
      |> to_string()
      |> String.trim_trailing("/")

    base_url <> "/" <> basename
  end

  defp media_type_from_extension(".pdf"), do: "application/pdf"
  defp media_type_from_extension(".png"), do: "image/png"
  defp media_type_from_extension(".jpg"), do: "image/jpeg"
  defp media_type_from_extension(".jpeg"), do: "image/jpeg"
  defp media_type_from_extension(".webp"), do: "image/webp"
  defp media_type_from_extension(".gif"), do: "image/gif"
  defp media_type_from_extension(".bmp"), do: "image/bmp"
  defp media_type_from_extension(".tif"), do: "image/tiff"
  defp media_type_from_extension(".tiff"), do: "image/tiff"
  defp media_type_from_extension(".heic"), do: "image/heic"
  defp media_type_from_extension(".heif"), do: "image/heif"
  defp media_type_from_extension(".mp4"), do: "video/mp4"
  defp media_type_from_extension(".m4v"), do: "video/mp4"
  defp media_type_from_extension(".mov"), do: "video/quicktime"
  defp media_type_from_extension(".webm"), do: "video/webm"
  defp media_type_from_extension(".mp3"), do: "audio/mpeg"
  defp media_type_from_extension(".m4a"), do: "audio/mp4"
  defp media_type_from_extension(".aac"), do: "audio/aac"
  defp media_type_from_extension(".wav"), do: "audio/wav"
  defp media_type_from_extension(".ogg"), do: "audio/ogg"
  defp media_type_from_extension(".oga"), do: "audio/ogg"
  defp media_type_from_extension(".opus"), do: "audio/ogg"
  defp media_type_from_extension(".flac"), do: "audio/flac"
  defp media_type_from_extension(".zip"), do: "application/zip"
  defp media_type_from_extension(".tgs"), do: "application/x-tgsticker"
  defp media_type_from_extension(_), do: nil

  defp fallback_extension_from_mime(media_type) when is_binary(media_type) do
    case MIME.extensions(media_type) do
      [extension | _] when is_binary(extension) and extension != "" ->
        "." <> extension

      _ ->
        nil
    end
  end

  defp normalize_media_type(media_type) when is_binary(media_type) do
    media_type
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
  end
end
