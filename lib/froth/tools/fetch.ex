defmodule Froth.Tools.Fetch do
  @moduledoc """
  Source-polymorphic fetch tool: brings external bytes into the agent
  context as a durable file, addressable by URL and (optionally)
  inlined as a multimodal content block.

  The `source` parameter accepts:

    * an integer or `"msg:N"` / `"tg:N"` string — Telegram message id;
      the file attached to that message is downloaded via TDLib.

    * an `https://` / `http://` URL — a HEAD probe sniffs the
      content-type. HTML pages route through `Froth.Web.Lightpanda`
      (Zig-based JS-enabled headless renderer) and come back as
      markdown; everything else streams via `Req.get/1`.

  In all cases the bytes are persisted via `Froth.DurableFiles.persist/3`
  (content-hashed, public URL via the unindexed file root) and
  returned to the agent as a single `<fetched>` `%Block{}` whose attrs
  carry the metadata. When `view: true`, the bytes ride along in the
  block body — text bodies fold into head/tail/blob via the normal
  block materialization, image and PDF bodies emit a multimodal
  content part for vision-capable providers.
  """

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block
  alias Froth.DurableFiles
  alias Froth.Telemetry.Span
  alias Froth.Web.Lightpanda

  defmodule Fetched do
    @moduledoc false

    @enforce_keys [:source]
    defstruct [
      :source,
      :data,
      :declared_media_type,
      :filename,
      :local_path,
      fallback_basename: "file",
      fallback_media_type: "application/octet-stream"
    ]
  end

  @impl true
  def name, do: "fetch"

  @impl true
  def label, do: "Fetch"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Fetch a resource and bring it into context. The `source` parameter accepts a Telegram message reference (`12345` or `\"msg:12345\"` from a `msg:` reference in the chat log) or an `http(s)://` URL. The bytes are saved as a local durable file (content-hashed, also lives in a public unindexed web root so it can be shared directly or passed to external APIs by URL) and returned to you as a `<fetched>` block whose attrs include `local_path`, `public_url`, `mime`, `size`, `filename`, and `source`. Web pages are rendered with a real JS-enabled headless browser and returned as markdown; non-HTML URLs stream through directly. If `view` is true (the default for images and textual content) the bytes are inlined — images and PDFs become multimodal content blocks; text-shaped bodies fold into head/tail/blob automatically and the pager can read them more fully. If `view` is false the file is only materialized and addressed, not inlined — useful for PDFs, video, audio, archives, large opaque binaries, or anything you want to process via shell or elixir_eval rather than load into context.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "source" => %{
            "type" => "string",
            "description" =>
              "Either a Telegram message reference (a positive integer like `12345` or the string `\"msg:12345\"` / `\"tg:12345\"`), or an http(s):// URL."
          },
          "view" => %{
            "type" => "boolean",
            "description" =>
              "Whether to inline the bytes in the block body. Defaults to true for images and textual content (markdown, JSON, XML, etc.); false for PDFs, audio, video, archives, and other opaque binaries — pass true explicitly when you want those inlined."
          }
        },
        "required" => ["source"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks) when is_map(input) do
    with {:ok, source} <- parse_source(input["source"] || input["message_id"]),
         {:ok, fetched} <- fetch_source(source, ctx),
         {:ok, media_type} <- resolve_media_type(fetched),
         {:ok, filename} <- resolve_filename(fetched, media_type),
         {:ok, metadata} <- DurableFiles.persist(fetched.data, media_type, filename),
         {:ok, view?} <- resolve_view(input["view"], media_type),
         {:ok, blocks} <- build_result_blocks(fetched, metadata, view?) do
      {:ok, blocks}
    end
  end

  # ── source parsing ───────────────────────────────────────────────

  defp parse_source(value) when is_integer(value) and value > 0 do
    {:ok, {:telegram, value}}
  end

  defp parse_source(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "Missing source. Provide a Telegram message id (msg:N) or an http(s):// URL."}

      url?(trimmed) ->
        {:ok, {:url, trimmed}}

      true ->
        parse_telegram_reference(trimmed)
    end
  end

  defp parse_source(nil) do
    {:error, "Missing source. Provide a Telegram message id (msg:N) or an http(s):// URL."}
  end

  defp parse_source(_),
    do: {:error, "Invalid source. Use msg:N for Telegram or an http(s):// URL."}

  defp url?(value) when is_binary(value) do
    String.starts_with?(value, ["http://", "https://"])
  end

  defp parse_telegram_reference(value) do
    normalized =
      value
      |> String.replace_prefix("msg:", "")
      |> String.replace_prefix("tg:", "")

    case Integer.parse(normalized) do
      {message_id, ""} when message_id > 0 ->
        {:ok, {:telegram, message_id}}

      _ ->
        {:error, "Invalid source. Use an integer like 12345, msg:12345, or an http(s):// URL."}
    end
  end

  # ── source dispatch ──────────────────────────────────────────────

  defp fetch_source({:telegram, message_id}, %Context{
         surface: %{chat_id: chat_id, session_id: session_id}
       })
       when is_integer(chat_id) and is_binary(session_id) do
    with {:ok, message} <- fetch_message_for_media(session_id, chat_id, message_id),
         {:ok, media} <- extract_fetch_media(message, message_id),
         {:ok, file_data, local_path} <- download_tdlib_file(session_id, media.file_id) do
      {:ok,
       %Fetched{
         source: "msg:#{message_id}",
         data: file_data,
         declared_media_type: media.declared_media_type,
         filename: media.filename,
         local_path: local_path,
         fallback_basename: telegram_basename(media.message_type, message_id),
         fallback_media_type: default_media_type_for_message_type(media.message_type)
       }}
    end
  end

  defp fetch_source({:telegram, _message_id}, %Context{}) do
    {:error, "Telegram source requires an active session and chat in the cycle context."}
  end

  defp fetch_source({:url, url}, %Context{} = _ctx) do
    Span.span(
      [:froth, :tools, :fetch, :url],
      nil,
      %{url: url},
      fn _span_id -> do_fetch_url(url) end
    )
  end

  defp do_fetch_url(url) do
    case head_content_type(url) do
      {:ok, content_type} ->
        if html_like?(content_type) do
          {fetch_via_lightpanda(url), %{outcome: :lightpanda, content_type: content_type}}
        else
          {fetch_via_req(url, content_type), %{outcome: :req, content_type: content_type}}
        end

      :unknown ->
        {fetch_via_req(url, nil), %{outcome: :req_blind}}
    end
  end

  # Many sites (Hacker News among them) return 405 Method Not Allowed
  # for HEAD but still set a Content-Type header on the error response
  # — that's still good enough to route on. We trust any HEAD that
  # gives us a content-type and only fall back to a "blind GET" when
  # the server is silent. If the routing turns out wrong, the GET in
  # `fetch_via_req` is still authoritative for the actual bytes.
  defp head_content_type(url) do
    case Req.head(url, redirect: true, retry: false, decode_body: false) do
      {:ok, %Req.Response{headers: headers}} ->
        case content_type_header(headers) do
          nil -> :unknown
          ct -> {:ok, ct}
        end

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp content_type_header(headers) when is_map(headers) do
    headers
    |> Map.get("content-type", [])
    |> List.wrap()
    |> List.first()
  end

  defp content_type_header(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"content-type", v} -> v
      {"Content-Type", v} -> v
      _ -> nil
    end)
  end

  defp html_like?(content_type) when is_binary(content_type) do
    base =
      content_type
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()

    base in ["text/html", "application/xhtml+xml"]
  end

  defp html_like?(_), do: false

  defp fetch_via_lightpanda(url) do
    case Lightpanda.fetch(url) do
      {:ok, markdown} ->
        {:ok,
         %Fetched{
           source: url,
           data: markdown,
           declared_media_type: "text/markdown",
           filename: filename_from_url(url, force_ext: ".md"),
           fallback_basename: hostname_basename(url),
           fallback_media_type: "text/markdown"
         }}

      {:error, :timeout} ->
        {:error, "lightpanda fetch timed out after 30s"}

      {:error, :missing_executable} ->
        {:error, "lightpanda binary not found on PATH"}

      {:error, {:exit, code, tail}} ->
        {:error, "lightpanda exited with #{code}: #{String.trim(tail)}"}
    end
  end

  defp fetch_via_req(url, declared_content_type) do
    case Req.get(url, redirect: true, decode_body: false) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 and is_binary(body) ->
        content_type = declared_content_type || content_type_header(headers)

        media_type =
          content_type &&
            content_type
            |> String.split(";", parts: 2)
            |> List.first()
            |> String.trim()
            |> String.downcase()

        {:ok,
         %Fetched{
           source: url,
           data: body,
           declared_media_type: media_type,
           filename: filename_from_url(url),
           fallback_basename: hostname_basename(url),
           fallback_media_type: media_type || "application/octet-stream"
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, "GET #{url} returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "GET #{url} failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "GET #{url} crashed: #{Exception.message(error)}"}
  end

  # Returns a filename derived from the URL path, or nil if the URL
  # has no useful basename (or its basename has no extension). nil
  # lets the post-resolution pipeline synthesize a name from the
  # fallback basename plus the media-type-derived extension, which
  # ensures downstream tooling sees a sensible file extension.
  defp filename_from_url(url, opts \\ []) when is_binary(url) do
    force_ext = Keyword.get(opts, :force_ext)

    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" and path != "/" ->
        base = path |> Path.basename() |> URI.decode()

        cond do
          base == "" -> nil
          force_ext -> Path.rootname(base) <> force_ext
          Path.extname(base) == "" -> nil
          true -> base
        end

      _ ->
        nil
    end
  end

  defp hostname_basename(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host |> String.replace(".", "-")

      _ ->
        "page"
    end
  end

  # ── post-resolution pipeline ─────────────────────────────────────

  defp resolve_media_type(%Fetched{} = fetched) do
    media_type =
      fetched.declared_media_type ||
        DurableFiles.media_type_from_filename(fetched.filename) ||
        DurableFiles.media_type_from_path(fetched.local_path) ||
        fetched.fallback_media_type

    {:ok, media_type}
  end

  defp resolve_filename(%Fetched{filename: filename}, _media_type)
       when is_binary(filename) and filename != "" do
    {:ok, filename}
  end

  defp resolve_filename(%Fetched{} = fetched, media_type) when is_binary(media_type) do
    extension = DurableFiles.extension_from_media_type(media_type) || ".bin"
    {:ok, fetched.fallback_basename <> "-" <> short_hash(fetched.data) <> extension}
  end

  defp resolve_view(nil, media_type) when is_binary(media_type) do
    {:ok, default_view_for_media_type(media_type)}
  end

  defp resolve_view(view, _media_type) when is_boolean(view), do: {:ok, view}

  defp resolve_view(_, _), do: {:error, "Invalid view. Use true or false."}

  # Default `view` per media type: inline images and textual content
  # by default; require an explicit `view: true` for PDFs, audio,
  # video, and opaque binaries (those can be very large, and the
  # agent can always re-fetch with view: true if it wants the bytes).
  defp default_view_for_media_type(media_type) when is_binary(media_type) do
    cond do
      String.starts_with?(media_type, "image/") -> true
      String.starts_with?(media_type, "text/") -> true
      media_type == "application/json" -> true
      media_type == "application/xml" -> true
      true -> false
    end
  end

  defp build_result_blocks(%Fetched{} = fetched, metadata, view?) when is_boolean(view?) do
    body = if view?, do: fetched.data, else: nil

    attrs = [
      kind: "fetched",
      source: fetched.source,
      mime: metadata["media_type"],
      filename: metadata["filename"],
      size: metadata["size_bytes"],
      public_url: metadata["public_url"],
      local_path: metadata["local_path"]
    ]

    {:ok, [Block.new(attrs, body)]}
  end

  defp short_hash(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  # ── Telegram backend (unchanged behavior) ────────────────────────

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
          {:ok, data} -> {:ok, data, path}
          {:error, reason} -> {:error, "downloaded file read failed: #{inspect(reason)}"}
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

  # ── Telegram helpers ─────────────────────────────────────────────

  defp telegram_basename("messagePhoto", _id), do: "photo"
  defp telegram_basename("messageDocument", _id), do: "document"
  defp telegram_basename("messageVideo", _id), do: "video"
  defp telegram_basename("messageAudio", _id), do: "audio"
  defp telegram_basename("messageVoiceNote", _id), do: "voice-note"
  defp telegram_basename("messageSticker", _id), do: "sticker"
  defp telegram_basename("messageAnimation", _id), do: "animation"
  defp telegram_basename("messageVideoNote", _id), do: "video-note"
  defp telegram_basename(_type, id), do: "msg-#{id}"

  defp default_media_type_for_message_type("messagePhoto"), do: "image/jpeg"
  defp default_media_type_for_message_type("messageDocument"), do: "application/octet-stream"
  defp default_media_type_for_message_type("messageVideo"), do: "video/mp4"
  defp default_media_type_for_message_type("messageAudio"), do: "audio/mpeg"
  defp default_media_type_for_message_type("messageVoiceNote"), do: "audio/ogg"
  defp default_media_type_for_message_type("messageSticker"), do: "application/octet-stream"
  defp default_media_type_for_message_type("messageAnimation"), do: "video/mp4"
  defp default_media_type_for_message_type("messageVideoNote"), do: "video/mp4"
  defp default_media_type_for_message_type(_), do: "application/octet-stream"

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
end
