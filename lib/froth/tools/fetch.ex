defmodule Froth.Tools.Fetch do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.DurableFiles

  @impl true
  def name, do: "fetch"

  @impl true
  def label, do: "Fetch media"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Fetch a media file attached to a Telegram message. The file is downloaded from Telegram, saved as a local durable file that also lives in a public unindexed web root (so it can be shared directly or passed to external APIs by URL), and returned to you as a small JSON metadata block containing `local_path`, `public_url`, `media_type`, `size_bytes`, and `filename`. If `view` is true (the default for images) the file is also inlined as a native multimodal content block you can inspect directly — useful for photos where you want to see the picture. If `view` is false the file is only materialized and addressed, not inlined — useful for PDFs, zips, audio, video, large files, or anything you want to process via shell or elixir_eval rather than load into context. All Telegram media types are supported (photo, video, audio, voice, document, sticker, animation).",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{
            "type" => "integer",
            "description" =>
              "Telegram message ID from the chat log, i.e. the number from a msg:12345 reference."
          },
          "view" => %{
            "type" => "boolean",
            "description" =>
              "Whether to inline the file as a multimodal content block. Defaults to true for images and false for everything else."
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
         {:ok, message} <- fetch_message_for_media(session_id, chat_id, message_id),
         {:ok, media} <- extract_fetch_media(message, message_id),
         {:ok, file_data, local_path} <- download_tdlib_file(session_id, media.file_id),
         {:ok, media_type} <- resolve_media_type(media, local_path),
         {:ok, filename} <- resolve_filename(media, media_type),
         {:ok, metadata} <- DurableFiles.persist(file_data, media_type, filename),
         {:ok, view?} <- resolve_view(input["view"], media_type),
         {:ok, blocks} <- build_result_blocks(file_data, view?, metadata) do
      {:ok, blocks}
    end
  end

  def execute(%Context{}, %ToolUse{}, _hooks),
    do: {:error, "Could not fetch media for the given input."}

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

  defp fetch_message_for_media(session_id, chat_id, message_id)
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

  defp extract_fetch_media(%{"content" => %{"@type" => "messagePhoto"} = content}, message_id) do
    sizes = get_in(content, ["photo", "sizes"]) || []
    largest = Enum.max_by(sizes, &photo_size_pixels/1, fn -> nil end)
    file_id = get_in(largest || %{}, ["photo", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messagePhoto",
         file_id: file_id,
         filename: nil,
         declared_media_type: nil
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable photo."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageDocument", "document" => document}},
         message_id
       )
       when is_map(document) do
    file_id = get_in(document, ["document", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageDocument",
         file_id: file_id,
         filename: present_string(document["file_name"]),
         declared_media_type:
           present_string(document["mime_type"]) ||
             DurableFiles.media_type_from_filename(document["file_name"])
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable document."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageVideo", "video" => video}},
         message_id
       )
       when is_map(video) do
    file_id = get_in(video, ["video", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageVideo",
         file_id: file_id,
         filename: present_string(video["file_name"]),
         declared_media_type:
           present_string(video["mime_type"]) ||
             DurableFiles.media_type_from_filename(video["file_name"])
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable video."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageAudio", "audio" => audio}},
         message_id
       )
       when is_map(audio) do
    file_id = get_in(audio, ["audio", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageAudio",
         file_id: file_id,
         filename: present_string(audio["file_name"]),
         declared_media_type:
           present_string(audio["mime_type"]) ||
             DurableFiles.media_type_from_filename(audio["file_name"])
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable audio file."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageVoiceNote", "voice_note" => voice_note}},
         message_id
       )
       when is_map(voice_note) do
    file_id = get_in(voice_note, ["voice", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageVoiceNote",
         file_id: file_id,
         filename: nil,
         declared_media_type: present_string(voice_note["mime_type"]) || "audio/ogg"
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable voice note."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageSticker", "sticker" => sticker}},
         message_id
       )
       when is_map(sticker) do
    file_id = get_in(sticker, ["sticker", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageSticker",
         file_id: file_id,
         filename: sticker_filename(sticker),
         declared_media_type: sticker_media_type(sticker)
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable sticker."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageAnimation", "animation" => animation}},
         message_id
       )
       when is_map(animation) do
    file_id = get_in(animation, ["animation", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageAnimation",
         file_id: file_id,
         filename: present_string(animation["file_name"]),
         declared_media_type:
           present_string(animation["mime_type"]) ||
             DurableFiles.media_type_from_filename(animation["file_name"])
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable animation."}
    end
  end

  defp extract_fetch_media(
         %{"content" => %{"@type" => "messageVideoNote", "video_note" => video_note}},
         message_id
       )
       when is_map(video_note) do
    file_id = get_in(video_note, ["video", "id"])

    if valid_file_id?(file_id) do
      {:ok,
       %{
         message_id: message_id,
         message_type: "messageVideoNote",
         file_id: file_id,
         filename: nil,
         declared_media_type: "video/mp4"
       }}
    else
      {:error, "Message msg:#{message_id} does not include a downloadable video note."}
    end
  end

  defp extract_fetch_media(_message, message_id) do
    {:error,
     "Message msg:#{message_id} is not a supported media message (photo, document, video, audio, voice note, sticker, animation, or video note)."}
  end

  defp resolve_media_type(media, local_path) when is_map(media) and is_binary(local_path) do
    media_type =
      media.declared_media_type ||
        DurableFiles.media_type_from_filename(media.filename) ||
        DurableFiles.media_type_from_path(local_path) ||
        default_media_type_for_message_type(media.message_type)

    {:ok, media_type}
  end

  defp resolve_media_type(_media, _local_path),
    do: {:error, "Could not determine media type for this message."}

  defp resolve_filename(%{filename: filename}, _media_type)
       when is_binary(filename) and filename != "" do
    {:ok, filename}
  end

  defp resolve_filename(%{message_type: message_type, message_id: message_id}, media_type)
       when is_binary(message_type) and is_integer(message_id) do
    basename =
      case message_type do
        "messagePhoto" -> "photo"
        "messageDocument" -> "document"
        "messageVideo" -> "video"
        "messageAudio" -> "audio"
        "messageVoiceNote" -> "voice-note"
        "messageSticker" -> "sticker"
        "messageAnimation" -> "animation"
        "messageVideoNote" -> "video-note"
        _ -> "file"
      end

    {:ok,
     "#{basename}-#{message_id}#{DurableFiles.extension_from_media_type(media_type) || ".bin"}"}
  end

  defp resolve_filename(_media, _media_type),
    do: {:error, "Could not determine a filename for this message."}

  defp resolve_view(nil, media_type) when is_binary(media_type),
    do: {:ok, String.starts_with?(media_type, "image/")}

  defp resolve_view(view, _media_type) when is_boolean(view), do: {:ok, view}

  defp resolve_view(_, _),
    do: {:error, "Invalid view. Use true or false."}

  defp build_result_blocks(file_data, view?, meta)
       when is_binary(file_data) and is_boolean(view?) and is_map(meta) do
    metadata_block = %{"type" => "text", "text" => Jason.encode!(meta, pretty: true)}

    case {view?, inline_content_block(meta["media_type"], file_data)} do
      {true, {:ok, block}} ->
        {:ok, [metadata_block, block]}

      {true, :skip} ->
        {:ok, [metadata_block]}

      {false, _} ->
        {:ok, [metadata_block]}
    end
  end

  defp inline_content_block(media_type, file_data)
       when is_binary(media_type) and is_binary(file_data) do
    normalized_media_type = normalize_media_type(media_type)

    cond do
      String.starts_with?(normalized_media_type, "image/") ->
        {:ok,
         %{
           "type" => "image",
           "source" => %{
             "type" => "base64",
             "media_type" => normalized_media_type,
             "data" => Base.encode64(file_data)
           }
         }}

      normalized_media_type == "application/pdf" ->
        {:ok,
         %{
           "type" => "document",
           "source" => %{
             "type" => "base64",
             "media_type" => "application/pdf",
             "data" => Base.encode64(file_data)
           }
         }}

      true ->
        :skip
    end
  end

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

  defp photo_size_pixels(size) when is_map(size) do
    (size["width"] || 0) * (size["height"] || 0)
  end

  defp photo_size_pixels(_), do: 0

  defp valid_file_id?(file_id) when is_integer(file_id), do: file_id > 0
  defp valid_file_id?(_), do: false

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_), do: nil

  defp sticker_media_type(%{"format" => %{"@type" => "stickerFormatWebp"}}), do: "image/webp"

  defp sticker_media_type(%{"format" => %{"@type" => "stickerFormatTgs"}}),
    do: "application/x-tgsticker"

  defp sticker_media_type(%{"format" => %{"@type" => "stickerFormatWebm"}}), do: "video/webm"
  defp sticker_media_type(_), do: "application/octet-stream"

  defp sticker_filename(sticker) when is_map(sticker) do
    case sticker_media_type(sticker) do
      "image/webp" -> "sticker.webp"
      "application/x-tgsticker" -> "sticker.tgs"
      "video/webm" -> "sticker.webm"
      _ -> nil
    end
  end

  defp default_media_type_for_message_type("messagePhoto"), do: "image/jpeg"
  defp default_media_type_for_message_type("messageDocument"), do: "application/octet-stream"
  defp default_media_type_for_message_type("messageVideo"), do: "video/mp4"
  defp default_media_type_for_message_type("messageAudio"), do: "audio/mpeg"
  defp default_media_type_for_message_type("messageVoiceNote"), do: "audio/ogg"
  defp default_media_type_for_message_type("messageSticker"), do: "application/octet-stream"
  defp default_media_type_for_message_type("messageAnimation"), do: "video/mp4"
  defp default_media_type_for_message_type("messageVideoNote"), do: "video/mp4"
  defp default_media_type_for_message_type(_), do: "application/octet-stream"

  defp normalize_media_type(media_type) when is_binary(media_type) do
    media_type
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
  end
end
