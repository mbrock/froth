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

  require Logger

  alias Froth.Telegram.SessionConfig

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
      {DynamicSupervisor, name: Froth.Telegram.SessionSupervisor, strategy: :one_for_one}
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
        DynamicSupervisor.terminate_child(Froth.Telegram.SessionSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  def list_sessions do
    Registry.select(Froth.Telegram.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # --- messaging ---

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Froth.PubSub, Froth.Telegram.Session.topic(session_id))
  end

  def send(session_id, request) do
    GenServer.cast(Froth.Telegram.Session.via(session_id), {:send, request})
  end

  def call(session_id, request, timeout \\ 30_000) do
    GenServer.call(Froth.Telegram.Session.via(session_id), {:call, request}, timeout)
  end

  @doc """
  Send a photo to a chat. Downloads HTTP URLs to a temp file first.
  Optional caption.

      Froth.Telegram.send_photo("charlie", chat_id, "https://example.com/img.webp", caption: "look at this")
  """
  def send_photo(session_id, chat_id, url, opts \\ []) do
    caption = Keyword.get(opts, :caption)

    with {:ok, file_ref} <- resolve_file(url, ".jpg") do
      content = %{
        "@type" => "inputMessagePhoto",
        "photo" => file_ref,
        "width" => 0,
        "height" => 0
      }

      content =
        if caption,
          do: Map.put(content, "caption", %{"@type" => "formattedText", "text" => caption}),
          else: content

      call(session_id, %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" => content
      })
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
        "width" => 0,
        "height" => 0,
        "duration" => 0
      }

      content =
        if caption,
          do: Map.put(content, "caption", %{"@type" => "formattedText", "text" => caption}),
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
          do: Map.put(content, "caption", %{"@type" => "formattedText", "text" => caption}),
          else: content

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

    case Finch.request(Finch.build(:get, url), Froth.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        File.write!(tmp, body)
        {:ok, %{"@type" => "inputFileLocal", "path" => tmp}}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, err} ->
        {:error, {:download_failed, err}}
    end
  end

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
      Logger.info(event: :auto_start, session: sc.id)
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
