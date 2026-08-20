defmodule Froth.Telegram.VideoHosting do
  @moduledoc """
  Archives large Telegram videos in the object store and announces one
  streamable URL from a deterministic bot identity present in the chat.
  """

  alias Froth.{HostedVideo, ObjectStore, Repo}
  alias Froth.Telegram.{BotAdapter, Bots}

  @default_threshold_bytes 100 * 1024 * 1024

  def host_message?(message) when is_map(message) do
    {_media, file} = media_and_file(message)
    size = file["expected_size"] || file["size"] || 0

    is_integer(size) and size >= threshold_bytes()
  end

  def resume(chat_id, message_id)
      when is_integer(chat_id) and is_integer(message_id) do
    case Repo.get_by(HostedVideo, chat_id: chat_id, message_id: message_id) do
      %HostedVideo{} = video -> announce(video)
      nil -> :not_hosted
    end
  end

  def maybe_host(message, path)
      when is_map(message) and is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size >= threshold_bytes(),
         {:ok, hosted_video} <- ensure_hosted(message, path, stat.size) do
      announce(hosted_video)
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def threshold_bytes do
    Application.get_env(:froth, __MODULE__, [])
    |> Keyword.get(:threshold_bytes, @default_threshold_bytes)
  end

  @doc false
  def choose_session(chat_id, configs, chat_lookup_fun \\ &chat_available?/2)
      when is_integer(chat_id) and is_list(configs) and
             is_function(chat_lookup_fun, 2) do
    configs
    |> Enum.uniq_by(& &1.session_id)
    |> Enum.filter(fn config ->
      chat_lookup_fun.(config, chat_id)
    end)
    |> Enum.max_by(&rendezvous_score(chat_id, &1.session_id), fn -> nil end)
    |> case do
      nil -> {:error, :no_bot_in_chat}
      config -> {:ok, config.session_id}
    end
  end

  defp ensure_hosted(message, path, content_length) do
    chat_id = message["chat_id"]
    message_id = message["id"]

    case Repo.get_by(HostedVideo, chat_id: chat_id, message_id: message_id) do
      %HostedVideo{} = video ->
        {:ok, video}

      nil ->
        {media, _file} = media_and_file(message)

        content_type =
          media["mime_type"] || MIME.from_path(path) ||
            "application/octet-stream"

        key = object_key(message, path)

        with {:ok, stored} <-
               ObjectStore.put_file(key, path, content_type: content_type) do
          attrs = %{
            chat_id: chat_id,
            message_id: message_id,
            object_key: stored.key,
            public_url: public_url(stored.key),
            content_type: stored.content_type,
            content_length: content_length
          }

          %HostedVideo{}
          |> HostedVideo.changeset(attrs)
          |> Repo.insert(
            on_conflict: :nothing,
            conflict_target: [:chat_id, :message_id]
          )
          |> case do
            {:ok, %HostedVideo{id: nil}} ->
              {:ok,
               Repo.get_by!(HostedVideo,
                 chat_id: chat_id,
                 message_id: message_id
               )}

            result ->
              result
          end
        end
    end
  end

  defp announce(%HostedVideo{announced_at: %DateTime{}}), do: :ok

  defp announce(%HostedVideo{} = video) do
    with {:ok, session_id} <- choose_session(video.chat_id, bot_configs()),
         {:ok, sent_message} <-
           BotAdapter.send_message(
             session_id,
             video.chat_id,
             "Here’s a streamable copy: #{video.public_url}",
             reply_to: video.message_id
           ) do
      video
      |> HostedVideo.changeset(%{
        announced_by: session_id,
        announcement_message_id: sent_message["id"],
        announced_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()
      |> case do
        {:ok, _video} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp bot_configs do
    Bots.list_bots()
    |> Enum.flat_map(fn bot_id ->
      try do
        [GenServer.call(Bots.via(bot_id), :snapshot)]
      catch
        :exit, _reason -> []
      end
    end)
  end

  defp chat_available?(
         %{session_id: session_id, bot_user_id: bot_user_id},
         chat_id
       )
       when is_integer(bot_user_id) and bot_user_id > 0 do
    case Froth.Telegram.call(
           session_id,
           %{
             "@type" => "getChatMember",
             "chat_id" => chat_id,
             "member_id" => %{
               "@type" => "messageSenderUser",
               "user_id" => bot_user_id
             }
           }
         ) do
      {:ok, %{"status" => %{"@type" => status}}}
      when status in [
             "chatMemberStatusCreator",
             "chatMemberStatusAdministrator",
             "chatMemberStatusMember"
           ] ->
        true

      {:ok,
       %{
         "status" => %{
           "@type" => "chatMemberStatusRestricted",
           "is_member" => true,
           "permissions" => permissions
         }
       }} ->
        permissions["can_send_basic_messages"] != false

      _ ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp chat_available?(_config, _chat_id), do: false

  defp rendezvous_score(chat_id, session_id) do
    :crypto.hash(:sha256, "#{chat_id}:#{session_id}")
  end

  defp object_key(message, path) do
    chat_id = message["chat_id"]
    message_id = message["id"]

    filename =
      message
      |> media_and_file()
      |> elem(0)
      |> Map.get("file_name")
      |> case do
        name when is_binary(name) and name != "" -> name
        _ -> "video#{Path.extname(path)}"
      end
      |> sanitize_filename()

    "telegram-videos/#{chat_id}/#{message_id}/#{filename}"
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9._-]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "video"
      safe -> safe
    end
  end

  defp public_url(key) do
    case Application.get_env(:froth, __MODULE__, [])[:public_base] do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/" <> key

      _ ->
        ObjectStore.public_url(key)
    end
  end

  defp media_and_file(%{"content" => %{"video" => media}})
       when is_map(media),
       do: {media, media["video"] || %{}}

  defp media_and_file(%{"content" => %{"document" => media}})
       when is_map(media),
       do: {media, media["document"] || %{}}

  defp media_and_file(_message), do: {%{}, %{}}
end
