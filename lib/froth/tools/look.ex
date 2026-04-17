defmodule Froth.Tools.Look do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse

  @impl true
  def name, do: "look"

  @impl true
  def label, do: "look at media"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Open a Telegram media message by msg:ID and return native multimodal content blocks. Use this when you want to inspect the actual image or PDF in context rather than relying only on a text analysis. The tool currently supports images and PDFs only; for voice notes, videos, links, and other media, prefer the existing analyses via view_analysis. The result includes a short metadata text block plus the binary content block the model can inspect directly.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{
            "type" => "integer",
            "description" =>
              "Telegram message ID from the chat log, i.e. the number from a msg:12345 reference."
          }
        },
        "required" => ["message_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(
        %Context{surface: %{chat_id: chat_id, session_id: session_id}},
        %ToolUse{input: input},
        _hooks
      )
      when is_integer(chat_id) and is_map(input) and is_binary(session_id) do
    with {:ok, message_id} <- parse_message_reference(input["message_id"]),
         {:ok, message} <- fetch_message_for_look(session_id, chat_id, message_id),
         {:ok, media} <- extract_look_media(message, message_id),
         {:ok, file_data, local_path} <- download_tdlib_file(session_id, media.file_id),
         {:ok, media_type} <- resolve_look_media_type(media, local_path),
         {:ok, content_block} <- look_content_block(media.kind, media_type, file_data) do
      metadata_text = look_metadata_text(media, media_type, byte_size(file_data))

      {:ok, [%{"type" => "text", "text" => metadata_text}, content_block]}
    end
  end

  def execute(%Context{}, %ToolUse{}, _hooks),
    do: {:error, "Could not open media for the given input."}

  defp parse_message_reference(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_message_reference(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace_prefix("msg:", "")
      |> String.replace_prefix("tg:", "")

    case Integer.parse(normalized) do
      {message_id, ""} when message_id > 0 ->
        {:ok, message_id}

      _ ->
        {:error, "Invalid message_id. Use an integer like 12345 or msg:12345."}
    end
  end

  defp parse_message_reference(_),
    do: {:error, "Invalid message_id. Use an integer like 12345 or msg:12345."}

  defp fetch_message_for_look(session_id, chat_id, message_id)
       when is_binary(session_id) and is_integer(chat_id) and is_integer(message_id) do
    case Froth.Telegram.call(
           session_id,
           %{
             "@type" => "getMessage",
             "chat_id" => chat_id,
             "message_id" => message_id
           },
           60_000
         ) do
      {:ok, %{"@type" => "error", "message" => reason}} ->
        {:error, "getMessage: #{reason}"}

      {:ok, message} when is_map(message) ->
        {:ok, message}

      {:error, reason} ->
        {:error, "getMessage failed: #{inspect(reason)}"}

      other ->
        {:error, "getMessage returned unexpected response: #{inspect(other)}"}
    end
  end

  defp extract_look_media(%{"content" => %{"@type" => "messagePhoto"} = content}, message_id) do
    sizes = get_in(content, ["photo", "sizes"]) || []
    largest = Enum.max_by(sizes, &photo_size_pixels/1, fn -> nil end)
    file_id = get_in(largest || %{}, ["photo", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messagePhoto",
         kind: :image,
         file_id: file_id,
         filename: nil,
         caption: caption_text(content),
         declared_media_type: nil
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable photo."}
    end
  end

  defp extract_look_media(
         %{"content" => %{"@type" => "messageDocument", "document" => document} = content},
         message_id
       )
       when is_map(document) do
    file_id = get_in(document, ["document", "id"])
    filename = document["file_name"] || "document"

    declared_media_type =
      document["mime_type"] ||
        media_type_from_filename(filename) ||
        "application/octet-stream"

    kind =
      cond do
        declared_media_type == "application/pdf" -> :pdf
        String.starts_with?(declared_media_type, "image/") -> :image
        true -> :unsupported
      end

    cond do
      not valid_file_id?(file_id) ->
        {:error, "Message msg:#{message_id} does not include a downloadable document."}

      kind == :unsupported ->
        {:error,
         "Message msg:#{message_id} is a #{inspect(declared_media_type)} document. " <>
           "look supports images and PDFs only."}

      true ->
        {:ok,
         %{
           message_id: message_id,
           message_type: "messageDocument",
           kind: kind,
           file_id: file_id,
           filename: filename,
           caption: caption_text(content),
           declared_media_type: declared_media_type
         }}
    end
  end

  defp extract_look_media(_message, message_id) do
    {:error, "Message msg:#{message_id} is not a photo or supported document (image/PDF)."}
  end

  defp photo_size_pixels(size) when is_map(size) do
    (size["width"] || 0) * (size["height"] || 0)
  end

  defp photo_size_pixels(_), do: 0

  defp valid_file_id?(file_id) when is_integer(file_id), do: file_id > 0
  defp valid_file_id?(_), do: false

  defp caption_text(content) when is_map(content) do
    get_in(content, ["caption", "text"]) || ""
  end

  defp caption_text(_), do: ""

  defp download_tdlib_file(session_id, file_id)
       when is_binary(session_id) and is_integer(file_id) do
    case Froth.Telegram.call(
           session_id,
           %{
             "@type" => "downloadFile",
             "file_id" => file_id,
             "priority" => 32,
             "synchronous" => true
           },
           180_000
         ) do
      {:ok, %{"local" => %{"path" => path}}} when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, data} ->
            {:ok, data, path}

          {:error, reason} ->
            {:error, "downloaded file read failed: #{inspect(reason)}"}
        end

      {:ok, %{"@type" => "error", "message" => reason}} ->
        {:error, "downloadFile: #{reason}"}

      {:error, reason} ->
        {:error, "downloadFile failed: #{inspect(reason)}"}

      {:ok, other} ->
        {:error, "downloadFile returned unexpected response: #{inspect(other)}"}
    end
  end

  defp download_tdlib_file(_session_id, _file_id),
    do: {:error, "Message does not include a valid downloadable file ID."}

  defp resolve_look_media_type(%{kind: :pdf}, _local_path), do: {:ok, "application/pdf"}

  defp resolve_look_media_type(
         %{kind: :image, declared_media_type: declared_media_type},
         local_path
       ) do
    media_type =
      cond do
        is_binary(declared_media_type) and String.starts_with?(declared_media_type, "image/") ->
          declared_media_type

        true ->
          image_media_type_from_path(local_path)
      end

    {:ok, media_type}
  end

  defp resolve_look_media_type(_media, _local_path),
    do: {:error, "Could not determine media type for this message."}

  defp look_content_block(:image, media_type, file_data)
       when is_binary(media_type) and is_binary(file_data) do
    {:ok,
     %{
       "type" => "image",
       "source" => %{
         "type" => "base64",
         "media_type" => media_type,
         "data" => Base.encode64(file_data)
       }
     }}
  end

  defp look_content_block(:pdf, _media_type, file_data) when is_binary(file_data) do
    {:ok,
     %{
       "type" => "document",
       "source" => %{
         "type" => "base64",
         "media_type" => "application/pdf",
         "data" => Base.encode64(file_data)
       }
     }}
  end

  defp look_content_block(_kind, _media_type, _file_data),
    do: {:error, "Unsupported media type for look tool."}

  defp look_metadata_text(media, media_type, size_bytes) when is_map(media) do
    base_lines = [
      "Loaded msg:#{media.message_id} (#{media.message_type}).",
      "kind: #{if(media.kind == :pdf, do: "pdf", else: "image")}",
      "media_type: #{media_type}",
      "size_bytes: #{size_bytes}"
    ]

    filename_line =
      if is_binary(media.filename) and media.filename != "" do
        "filename: #{media.filename}"
      else
        nil
      end

    caption_line =
      case String.trim(media.caption || "") do
        "" -> nil
        caption -> "caption: #{String.slice(caption, 0, 300)}"
      end

    (base_lines ++ [filename_line, caption_line])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp media_type_from_filename(filename) when is_binary(filename) do
    case filename |> String.downcase() |> Path.extname() do
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".bmp" -> "image/bmp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> nil
    end
  end

  defp media_type_from_filename(_), do: nil

  defp image_media_type_from_path(path) when is_binary(path) do
    case path |> String.downcase() |> Path.extname() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".bmp" -> "image/bmp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> "image/jpeg"
    end
  end

  defp image_media_type_from_path(_), do: "image/jpeg"
end
