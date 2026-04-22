defmodule Froth.Telegram do
  @moduledoc """
  Multi-session TDLib bridge.

  Sessions maintain independent TDLib state and share one TDLib C node process.
  Sessions are identified by string IDs (e.g. "default", "bot-alerts").

  A "default" session is auto-started when `TELEGRAM_TDLIB_ENABLED=1`.

  ## Usage

      Froth.Telegram.subscribe("default")
      Froth.Telegram.send("default", %{"@type" => "getMe"})
      Froth.Telegram.call("default", %{"@type" => "getMe"})

      Froth.Telegram.start_session(%{id: "other-bot", api_id: 12345, api_hash: "..."})
      Froth.Telegram.stop_session("other-bot")
      Froth.Telegram.list_sessions()
  """

  use Supervisor

  import Kernel, except: [send: 2]
  import Ecto.Query

  alias Froth.DurableFiles
  alias Froth.Telegram.SessionConfig
  alias Span
  alias Vix.Vips.Image, as: Vimage

  def start_link(_opts) do
    result = Supervisor.start_link(__MODULE__, [], name: __MODULE__)

    case result do
      {:ok, _pid} -> auto_start_sessions()
      _ -> :ok
    end

    result
  end

  @impl true
  def init([]) do
    children = [
      {Registry, keys: :unique, name: Froth.Telegram.Registry},
      Froth.Telegram.Cnode,
      {DynamicSupervisor,
       name: Froth.Telegram.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # --- session management ---

  def start_session(config) when is_map(config) do
    DynamicSupervisor.start_child(
      Froth.Telegram.SessionSupervisor,
      {Froth.Telegram.Session, config}
    )
  end

  def stop_session(id) do
    case Registry.lookup(Froth.Telegram.Registry, id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(
          Froth.Telegram.SessionSupervisor,
          pid
        )

      [] ->
        {:error, :not_found}
    end
  end

  def list_sessions do
    Registry.select(Froth.Telegram.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # --- messaging ---

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(
      Froth.PubSub,
      Froth.Telegram.Session.topic(session_id)
    )
  end

  @doc "PubSub topic for persisted updates scoped to one Telegram chat."
  def chat_topic(chat_id) when is_integer(chat_id),
    do: "telegram:chat:#{chat_id}"

  def send(session_id, request) do
    GenServer.cast(Froth.Telegram.Session.via(session_id), {:send, request})
  end

  def call(session_id, request, timeout \\ 30_000) do
    GenServer.call(
      Froth.Telegram.Session.via(session_id),
      {:call, request},
      timeout
    )
  end

  @doc """
  Send one image or an image album to a chat.

  Accepts:

    * a local path
    * an HTTP URL
    * a `%Vix.Vips.Image{}`
    * an `Nx.Tensor`
    * a list of any of the above

  When given multiple images, sends them as a Telegram album. If
  `caption` is provided for an album, it is attached to the first
  image.

      Froth.Telegram.send_image("charlie", chat_id, "/tmp/render.png", caption: "look at this")

      Froth.Telegram.send_image("charlie", chat_id, [image_a, image_b],
        caption: "two variants"
      )
  """
  def send_image(session_id, chat_id, images, opts \\ [])

  def send_image(session_id, chat_id, [], _opts)
      when is_binary(session_id) and is_integer(chat_id) do
    {:error, "send_image requires at least one image"}
  end

  def send_image(session_id, chat_id, [image], opts)
      when is_binary(session_id) and is_integer(chat_id) and is_list(opts) do
    send_image(session_id, chat_id, image, opts)
  end

  def send_image(session_id, chat_id, images, opts)
      when is_binary(session_id) and is_integer(chat_id) and is_list(images) and
             is_list(opts) do
    if length(images) > 10 do
      {:error, "Telegram image albums support at most 10 images"}
    else
      with {:ok, prepared_images} <- prepare_album_images(images),
           {:ok, _response} <-
             %{
               "@type" => "sendMessageAlbum",
               "chat_id" => chat_id,
               "input_message_contents" =>
                 album_contents(prepared_images, opts)
             }
             |> maybe_put_reply_to(opts[:reply_to])
             |> then(&call(session_id, &1)) do
        {:ok, Enum.map(prepared_images, & &1.metadata)}
      end
    end
  end

  def send_image(session_id, chat_id, image, opts)
      when is_binary(session_id) and is_integer(chat_id) and is_list(opts) do
    with {:ok, prepared_image} <- prepare_image(image),
         {:ok, _response} <-
           %{
             "@type" => "sendMessage",
             "chat_id" => chat_id,
             "input_message_content" =>
               photo_content(
                 prepared_image.file_ref,
                 maybe_append_png_links(opts, [prepared_image.metadata])
               )
           }
           |> maybe_put_reply_to(opts[:reply_to])
           |> then(&call(session_id, &1)) do
      {:ok, prepared_image.metadata}
    end
  end

  @doc """
  Send a photo to a chat. Downloads HTTP URLs to a durable file first.
  Optional caption.

      Froth.Telegram.send_photo("charlie", chat_id, "https://example.com/img.webp", caption: "look at this")
  """
  def send_photo(session_id, chat_id, image, opts \\ []) do
    with {:ok, prepared_image} <- prepare_image(image) do
      %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" =>
          photo_content(prepared_image.file_ref, opts)
      }
      |> maybe_put_reply_to(opts[:reply_to])
      |> then(&call(session_id, &1))
    end
  end

  @doc """
  Send a video to a chat. Downloads HTTP URLs to a temp file first.
  Optional caption.

      Froth.Telegram.send_video("charlie", chat_id, "https://example.com/vid.mp4", caption: "watch this")
  """
  def send_video(session_id, chat_id, url, opts \\ []) do
    caption = Keyword.get(opts, :caption)

    with {:ok, file_ref} <- resolve_file(url, ".mp4") do
      content = %{
        "@type" => "inputMessageVideo",
        "video" => file_ref,
        "width" => Keyword.get(opts, :width, 0),
        "height" => Keyword.get(opts, :height, 0),
        "duration" => 0
      }

      content =
        if caption,
          do:
            Map.put(content, "caption", %{
              "@type" => "formattedText",
              "text" => caption
            }),
          else: content

      call(session_id, %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" => content
      })
    end
  end

  @doc """
  Send an audio file to a chat. Accepts a local path or HTTP URL.
  Optional caption.

      Froth.Telegram.send_audio("charlie", chat_id, "/tmp/podcast.mp3", caption: "listen")
  """
  def send_audio(session_id, chat_id, url, opts \\ []) do
    caption = Keyword.get(opts, :caption)

    with {:ok, file_ref} <- resolve_file(url, ".mp3") do
      content = %{
        "@type" => "inputMessageAudio",
        "audio" => file_ref,
        "duration" => 0
      }

      content =
        if caption,
          do:
            Map.put(content, "caption", %{
              "@type" => "formattedText",
              "text" => caption
            }),
          else: content

      call(session_id, %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" => content
      })
    end
  end

  @doc """
  Send a document to a chat. Accepts a local path or HTTP URL.
  Optional caption and caption entities.

      Froth.Telegram.send_document("charlie", chat_id, "/tmp/summary.html",
        caption: "2026-03-22\\n\\nLaunch day",
        caption_entities: [...]
      )
  """
  def send_document(session_id, chat_id, url, opts \\ []) do
    caption = Keyword.get(opts, :caption)
    caption_entities = Keyword.get(opts, :caption_entities)

    with {:ok, file_ref} <- resolve_file(url, ".html") do
      content = %{
        "@type" => "inputMessageDocument",
        "document" => file_ref
      }

      content =
        if is_binary(caption) and caption != "" do
          Map.put(
            content,
            "caption",
            formatted_text(caption, caption_entities)
          )
        else
          content
        end

      call(session_id, %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" => content
      })
    end
  end

  defp resolve_file(url, default_ext) when is_binary(url) do
    if String.starts_with?(url, "http") do
      download_to_temp(url, default_ext)
    else
      {:ok, %{"@type" => "inputFileLocal", "path" => url}}
    end
  end

  defp prepare_album_images(images) when is_list(images) do
    images
    |> Enum.reduce_while({:ok, []}, fn image, {:ok, acc} ->
      case prepare_image(image) do
        {:ok, prepared_image} ->
          {:cont, {:ok, acc ++ [prepared_image]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_image(input) do
    with {:ok,
          %{file_data: file_data, filename: filename, media_type: media_type}} <-
           image_data(input),
         {:ok, metadata} <-
           DurableFiles.persist(file_data, media_type, filename) do
      {:ok,
       %{
         metadata: metadata,
         file_ref: %{
           "@type" => "inputFileLocal",
           "path" => metadata["local_path"]
         }
       }}
    end
  end

  defp image_data(input)

  defp image_data(input) when is_binary(input) do
    if String.starts_with?(input, "http") do
      download_image_data(input, ".png")
    else
      image_data_from_path(input)
    end
  end

  defp image_data(%Vimage{} = image) do
    original_filename = image_filename(image)
    suffix = DurableFiles.extension_from_filename(original_filename) || ".png"
    filename = ensure_image_filename(original_filename, suffix)

    with {:ok, file_data} <- Image.write(image, :memory, suffix: suffix) do
      {:ok,
       %{
         file_data: file_data,
         filename: filename,
         media_type:
           DurableFiles.media_type_from_filename(filename) ||
             "image/png"
       }}
    else
      {:error, reason} ->
        {:error, {:image_write_failed, reason}}
    end
  end

  defp image_data(%Nx.Tensor{} = tensor) do
    with {:ok, image} <- Image.from_nx(tensor) do
      image_data(image)
    else
      {:error, reason} -> {:error, {:image_from_nx_failed, reason}}
    end
  end

  defp image_data(_input) do
    {:error,
     "Unsupported image input. Use a local path, URL, Image value, or Nx tensor."}
  end

  defp image_data_from_path(path) when is_binary(path) do
    with {:ok, file_data} <- File.read(path) do
      filename = Path.basename(path)

      {:ok,
       %{
         file_data: file_data,
         filename: filename,
         media_type:
           DurableFiles.media_type_from_path(path) ||
             DurableFiles.media_type_from_filename(filename) ||
             "image/png"
       }}
    else
      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  defp download_image_data(url, default_ext)
       when is_binary(url) and is_binary(default_ext) do
    filename = filename_from_url(url, default_ext)

    case Finch.request(Finch.build(:get, url), Froth.Finch,
           receive_timeout: 120_000
         ) do
      {:ok, %Finch.Response{status: 200, body: body, headers: headers}} ->
        {:ok,
         %{
           file_data: body,
           filename: filename,
           media_type:
             content_type_from_headers(headers) ||
               DurableFiles.media_type_from_filename(filename) ||
               "image/png"
         }}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, err} ->
        {:error, {:download_failed, err}}
    end
  end

  defp download_to_temp(url, default_ext) do
    ext =
      case URI.parse(url).path do
        nil ->
          default_ext

        path ->
          Path.extname(path)
          |> case do
            "" -> default_ext
            e -> e
          end
      end

    tmp =
      Path.join(
        System.tmp_dir!(),
        "froth_#{:crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower)}#{ext}"
      )

    case Finch.request(Finch.build(:get, url), Froth.Finch,
           receive_timeout: 120_000
         ) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        File.write!(tmp, body)
        {:ok, %{"@type" => "inputFileLocal", "path" => tmp}}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, err} ->
        {:error, {:download_failed, err}}
    end
  end

  defp image_filename(%Vimage{} = image) do
    case Image.filename(image) do
      path when is_binary(path) and path != "" -> Path.basename(path)
      _ -> nil
    end
  end

  defp ensure_image_filename(filename, suffix)
       when is_binary(filename) and filename != "" and is_binary(suffix) do
    case DurableFiles.extension_from_filename(filename) do
      extension when is_binary(extension) -> filename
      _ -> filename <> suffix
    end
  end

  defp ensure_image_filename(_filename, suffix) when is_binary(suffix),
    do: "image#{suffix}"

  defp filename_from_url(url, default_ext)
       when is_binary(url) and is_binary(default_ext) do
    case URI.parse(url).path do
      path when is_binary(path) and path != "" ->
        case Path.basename(path) do
          "" -> "image#{default_ext}"
          "/" -> "image#{default_ext}"
          basename -> basename
        end

      _ ->
        "image#{default_ext}"
    end
  end

  defp content_type_from_headers(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"content-type", value} when is_binary(value) -> value
      {"Content-Type", value} when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp content_type_from_headers(_headers), do: nil

  defp album_contents(prepared_images, opts)
       when is_list(prepared_images) and is_list(opts) do
    metadatas = Enum.map(prepared_images, & &1.metadata)
    first_item_opts = maybe_append_png_links(opts, metadatas)

    prepared_images
    |> Enum.with_index()
    |> Enum.map(fn {%{file_ref: file_ref}, index} ->
      item_opts = if index == 0, do: first_item_opts, else: []
      photo_content(file_ref, item_opts)
    end)
  end

  defp photo_content(file_ref, opts)
       when is_map(file_ref) and is_list(opts) do
    content = %{
      "@type" => "inputMessagePhoto",
      "photo" => file_ref,
      "width" => Keyword.get(opts, :width, 0),
      "height" => Keyword.get(opts, :height, 0)
    }

    caption = Keyword.get(opts, :caption)
    caption_entities = Keyword.get(opts, :caption_entities)

    if is_binary(caption) and caption != "" do
      Map.put(content, "caption", formatted_text(caption, caption_entities))
    else
      content
    end
  end

  defp maybe_append_png_links(opts, metadatas)
       when is_list(opts) and is_list(metadatas) do
    urls =
      metadatas
      |> Enum.map(fn
        %{"public_url" => url} when is_binary(url) and url != "" -> url
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      Keyword.get(opts, :include_png_link, true) == false ->
        opts

      urls == [] ->
        opts

      true ->
        caption = Keyword.get(opts, :caption) || ""
        entities = Keyword.get(opts, :caption_entities) || []

        {new_caption, new_entities} =
          append_png_link_footer(caption, entities, urls)

        opts
        |> Keyword.put(:caption, new_caption)
        |> Keyword.put(:caption_entities, new_entities)
    end
  end

  defp append_png_link_footer(caption, entities, [single_url]) do
    base = to_string(caption)
    separator = if base == "", do: "", else: " · "
    offset = utf16_length(base) + utf16_length(separator)
    arrow = "↗"
    new_text = base <> separator <> arrow
    link_entity = url_entity(offset, utf16_length(arrow), single_url)
    {new_text, entities ++ [link_entity]}
  end

  defp append_png_link_footer(caption, entities, urls) when is_list(urls) do
    base = to_string(caption)
    separator = if base == "", do: "", else: " · "
    prefix = base <> separator

    {parts_rev, _} =
      urls
      |> Enum.with_index(1)
      |> Enum.reduce({[], utf16_length(prefix)}, fn {url, idx},
                                                    {acc, offset} ->
        between = if acc == [], do: "", else: " · "
        between_len = utf16_length(between)
        label = Integer.to_string(idx)
        label_len = utf16_length(label)
        entity = url_entity(offset + between_len, label_len, url)
        {[{between, label, entity} | acc], offset + between_len + label_len}
      end)

    parts = Enum.reverse(parts_rev)

    suffix =
      Enum.map_join(parts, "", fn {between, label, _} -> between <> label end)

    new_text = prefix <> suffix
    new_entities = entities ++ Enum.map(parts, fn {_, _, e} -> e end)
    {new_text, new_entities}
  end

  defp url_entity(offset, length, url)
       when is_integer(offset) and is_integer(length) and is_binary(url) do
    %{
      "@type" => "textEntity",
      "offset" => offset,
      "length" => length,
      "type" => %{"@type" => "textEntityTypeTextUrl", "url" => url}
    }
  end

  defp utf16_length(text) when is_binary(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp formatted_text(text, entities) when is_binary(text) do
    case entities do
      entities when is_list(entities) ->
        %{
          "@type" => "formattedText",
          "text" => text,
          "entities" => entities
        }

      _ ->
        %{
          "@type" => "formattedText",
          "text" => text
        }
    end
  end

  defp maybe_put_reply_to(payload, nil), do: payload
  defp maybe_put_reply_to(payload, 0), do: payload

  defp maybe_put_reply_to(payload, message_id)
       when is_map(payload) and is_integer(message_id) and message_id > 0 do
    Map.put(payload, "reply_to", %{
      "@type" => "inputMessageReplyToMessage",
      "message_id" => message_id
    })
  end

  defp maybe_put_reply_to(payload, _message_id), do: payload

  # --- text drafts (Bot API 9.3, DM only) ---
  # Streams partial message text to a user while generating.
  # Requires "Topics in Direct Messages" enabled via BotFather web UI.
  # Only works in private (user) chats, not groups.
  # Flow: send_draft/4 repeatedly with same draft_id, then sendMessage to finalize.

  @doc """
  Returns a sendTextMessageDraft request map. The user sees a "generating..."
  spinner with the partial text, updated each call. Same `draft_id` = same draft.
  Finalize by sending a regular message.
  """
  def text_draft(chat_id, draft_id, text) when is_binary(text) do
    %{
      "@type" => "sendTextMessageDraft",
      "chat_id" => chat_id,
      "forum_topic_id" => 0,
      "draft_id" => draft_id,
      "text" => %{"@type" => "formattedText", "text" => text}
    }
  end

  # --- private ---

  @doc """
  Create or update a session config in the database.
  """
  def save_session(attrs) when is_map(attrs) do
    id = attrs[:id] || attrs["id"]

    case Froth.Repo.get(SessionConfig, id) do
      nil -> %SessionConfig{}
      existing -> existing
    end
    |> SessionConfig.changeset(attrs)
    |> Froth.Repo.insert_or_update()
  end

  @doc """
  Delete a session config from the database and stop the session if running.
  """
  def delete_session(id) do
    stop_session(id)

    case Froth.Repo.get(SessionConfig, id) do
      nil -> {:error, :not_found}
      config -> Froth.Repo.delete(config)
    end
  end

  defp auto_start_sessions do
    SessionConfig
    |> where(enabled: true)
    |> Froth.Repo.all()
    |> Enum.each(fn sc ->
      config = SessionConfig.to_session_config(sc)
      Span.execute([:froth, :telegram, :auto_start], nil, %{session: sc.id})
      start_session(config)
      start_sync(sc.id)
    end)
  end

  defp start_sync(session_id) do
    DynamicSupervisor.start_child(
      Froth.Telegram.SessionSupervisor,
      {Froth.Telegram.Sync, session_id}
    )
  end
end
