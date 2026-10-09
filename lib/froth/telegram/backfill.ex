defmodule Froth.Telegram.Backfill do
  @moduledoc """
  Imports Telethon message dumps as native-shaped TDLib messages.

  Telegram's MTProto message ids are converted to TDLib ids by shifting them
  left 20 bits. Media metadata is retained only as a recovery marker: TDLib
  file ids cannot be derived from a Telethon dump.
  """

  alias Froth.Repo
  alias Froth.Telegram.Message

  @id_shift 20
  @default_host "daniel@34.170.164.0"
  @default_remote_dir "/home/daniel/events-relay"

  @doc "Pull matching JSON files from the relay host into a staging directory."
  def pull!(opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    chat_id = Keyword.fetch!(opts, :chat_id)
    host = Keyword.get(opts, :host, @default_host)
    remote_dir = Keyword.get(opts, :remote_dir, @default_remote_dir)
    staging_dir = Keyword.fetch!(opts, :staging_dir)

    File.mkdir_p!(staging_dir)

    includes =
      from
      |> Date.range(to)
      |> Enum.flat_map(fn date ->
        stamp = date |> Date.to_iso8601() |> String.replace("-", "")
        ["--include=#{stamp}*cid=#{chat_id}*.tg.json"]
      end)

    args =
      ["-a", "--prune-empty-dirs", "--include=*/"] ++
        includes ++
        ["--exclude=*", "#{host}:#{remote_dir}/", staging_dir <> "/"]

    case System.cmd("rsync", args, stderr_to_stdout: true) do
      {_output, 0} -> staging_dir
      {output, status} -> raise "rsync failed (#{status}): #{output}"
    end
  end

  @doc "Translate one decoded Telethon `Message` or `MessageService` map."
  def translate(%{"_" => kind, "id" => id, "date" => date} = source, chat_id)
      when kind in ["Message", "MessageService"] and is_integer(id) do
    with {:ok, unix} <- unix_date(date),
         {:ok, sender} <- sender(source["from_id"]) do
      raw = %{
        "@type" => "message",
        "id" => tdlib_id(id),
        "date" => unix,
        "chat_id" => chat_id,
        "sender_id" => sender,
        "is_outgoing" => source["out"] == true,
        "is_channel_post" => source["post"] == true,
        "content" => content(source),
        "froth_backfill" => recovery_marker(source)
      }

      {:ok, maybe_reply(raw, source["reply_to"], chat_id)}
    end
  end

  def translate(source, _chat_id),
    do: {:error, {:unsupported_message, source["_"]}}

  @doc "Translate every JSON file in a staging directory."
  def load(staging_dir, chat_id) do
    staging_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      with {:ok, body} <- File.read(path),
           {:ok, source} <- Jason.decode(body),
           {:ok, raw} <- translate(source, chat_id) do
        {:ok, path, raw}
      else
        {:error, reason} -> {:error, path, reason}
      end
    end)
  end

  @doc "Insert translated messages for one session, ignoring existing rows."
  def insert(session_id, translations) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    translations
    |> Enum.flat_map(fn
      {:ok, _path, raw} ->
        [
          %{
            telegram_session_id: session_id,
            chat_id: raw["chat_id"],
            message_id: raw["id"],
            sender_id: Message.extract_sender_id(raw),
            date: raw["date"],
            raw: raw,
            inserted_at: now
          }
        ]

      {:error, _path, _reason} ->
        []
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.reduce(0, fn rows, count ->
      {inserted, _} =
        Repo.insert_all(Message, rows,
          on_conflict: :nothing,
          conflict_target: [:telegram_session_id, :chat_id, :message_id]
        )

      count + inserted
    end)
  end

  @doc "Summarize translated input by UTC day and return representative samples."
  def dry_run(translations, sample_count \\ 3) do
    valid = for {:ok, _path, raw} <- translations, do: raw
    errors = for {:error, path, reason} <- translations, do: {path, reason}

    per_day =
      valid
      |> Enum.frequencies_by(fn raw ->
        raw["date"] |> DateTime.from_unix!() |> DateTime.to_date()
      end)
      |> Enum.sort_by(fn {date, _count} -> Date.to_iso8601(date) end)

    %{
      total: length(valid),
      errors: errors,
      per_day: per_day,
      samples: Enum.take(valid, sample_count)
    }
  end

  def tdlib_id(id) when is_integer(id), do: Bitwise.bsl(id, @id_shift)

  defp unix_date(date) when is_binary(date) do
    case DateTime.from_iso8601(String.replace(date, " ", "T", global: false)) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime)}
      {:error, reason} -> {:error, {:invalid_date, date, reason}}
    end
  end

  defp unix_date(_), do: {:error, :missing_date}

  defp sender(%{"_" => "PeerUser", "user_id" => id}),
    do: {:ok, %{"@type" => "messageSenderUser", "user_id" => id}}

  defp sender(%{"_" => "PeerChannel", "channel_id" => id}),
    do:
      {:ok,
       %{"@type" => "messageSenderChat", "chat_id" => channel_chat_id(id)}}

  defp sender(%{"_" => "PeerChat", "chat_id" => id}),
    do: {:ok, %{"@type" => "messageSenderChat", "chat_id" => -id}}

  defp sender(nil),
    do: {:ok, %{"@type" => "messageSenderChat", "chat_id" => 0}}

  defp sender(value), do: {:error, {:unsupported_sender, value}}

  defp channel_chat_id(id), do: String.to_integer("-100#{id}")

  defp content(%{"_" => "MessageService", "action" => action}) do
    text_content("[Telegram service message: #{service_action(action)}]")
  end

  defp content(source) do
    text = source["message"] || ""
    entities = entities(source["entities"] || [])

    case source["media"] do
      nil ->
        text_content(text, entities)

      %{"_" => "MessageMediaWebPage"} ->
        text_content(text, entities)

      %{"_" => "MessageMediaPhoto"} ->
        caption_content("messagePhoto", text, entities)

      %{"_" => "MessageMediaGeo", "geo" => geo} ->
        location_content(geo)

      %{"_" => "MessageMediaDocument"} = media ->
        document_content(media, text, entities)

      %{"_" => type} ->
        text_content(media_placeholder(type, text), entities)
    end
  end

  defp text_content(text, entities \\ []) do
    %{
      "@type" => "messageText",
      "text" => %{
        "@type" => "formattedText",
        "text" => text,
        "entities" => entities
      }
    }
  end

  defp caption_content(type, text, entities) do
    %{
      "@type" => type,
      "caption" => %{
        "@type" => "formattedText",
        "text" => text,
        "entities" => entities
      }
    }
  end

  defp location_content(geo) do
    %{
      "@type" => "messageLocation",
      "location" => %{
        "@type" => "location",
        "latitude" => geo["lat"],
        "longitude" => geo["long"],
        "horizontal_accuracy" => geo["accuracy_radius"] || 0.0
      },
      "live_period" => 0,
      "expires_in" => 0,
      "heading" => 0,
      "proximity_alert_radius" => 0
    }
  end

  defp document_content(media, text, entities) do
    attributes = get_in(media, ["document", "attributes"]) || []

    type =
      cond do
        media["voice"] == true or
            attribute?(attributes, "DocumentAttributeAudio", "voice") ->
          "messageVoiceNote"

        media["round"] == true ->
          "messageVideoNote"

        media["video"] == true or
            attribute?(attributes, "DocumentAttributeVideo") ->
          "messageVideo"

        attribute?(attributes, "DocumentAttributeAnimated") ->
          "messageAnimation"

        attribute?(attributes, "DocumentAttributeSticker") ->
          "messageSticker"

        attribute?(attributes, "DocumentAttributeAudio") ->
          "messageAudio"

        true ->
          "messageDocument"
      end

    caption_content(type, text, entities)
  end

  defp attribute?(attributes, type, flag \\ nil) do
    Enum.any?(attributes, fn attribute ->
      attribute["_"] == type and (is_nil(flag) or attribute[flag] == true)
    end)
  end

  defp media_placeholder(type, ""),
    do: "[Telegram media unavailable: #{type}]"

  defp media_placeholder(type, text),
    do: text <> "\n\n[Telegram media unavailable: #{type}]"

  defp recovery_marker(source) do
    media = source["media"]

    %{
      "source" => "events-relay/telethon",
      "mtproto_message_id" => source["id"],
      "media_recovery_required" =>
        is_map(media) and media["_"] not in ["MessageMediaWebPage"]
    }
  end

  defp maybe_reply(raw, %{"reply_to_msg_id" => id}, chat_id)
       when is_integer(id) do
    Map.put(raw, "reply_to", %{
      "@type" => "messageReplyToMessage",
      "chat_id" => chat_id,
      "message_id" => tdlib_id(id),
      "origin_send_date" => 0
    })
  end

  defp maybe_reply(raw, _reply, _chat_id), do: raw

  defp entities(values), do: Enum.flat_map(values, &entity/1)

  defp entity(
         %{"_" => source_type, "offset" => offset, "length" => length} =
           source
       ) do
    case entity_type(source_type, source) do
      nil ->
        []

      type ->
        [
          %{
            "@type" => "textEntity",
            "offset" => offset,
            "length" => length,
            "type" => type
          }
        ]
    end
  end

  defp entity(_), do: []

  @simple_entity_types %{
    "MessageEntityMention" => "Mention",
    "MessageEntityHashtag" => "Hashtag",
    "MessageEntityCashtag" => "Cashtag",
    "MessageEntityBotCommand" => "BotCommand",
    "MessageEntityUrl" => "Url",
    "MessageEntityEmail" => "EmailAddress",
    "MessageEntityBold" => "Bold",
    "MessageEntityItalic" => "Italic",
    "MessageEntityUnderline" => "Underline",
    "MessageEntityStrike" => "Strikethrough",
    "MessageEntitySpoiler" => "Spoiler",
    "MessageEntityCode" => "Code",
    "MessageEntityPhone" => "PhoneNumber",
    "MessageEntityBlockquote" => "BlockQuote"
  }

  defp entity_type("MessageEntityTextUrl", source),
    do: %{"@type" => "textEntityTypeTextUrl", "url" => source["url"]}

  defp entity_type("MessageEntityMentionName", source),
    do: %{
      "@type" => "textEntityTypeMentionName",
      "user_id" => source["user_id"]
    }

  defp entity_type("MessageEntityPre", source),
    do: %{
      "@type" => "textEntityTypePreCode",
      "language" => source["language"] || ""
    }

  defp entity_type("MessageEntityCustomEmoji", source),
    do: %{
      "@type" => "textEntityTypeCustomEmoji",
      "custom_emoji_id" => to_string(source["document_id"])
    }

  defp entity_type(source_type, _source) do
    case @simple_entity_types[source_type] do
      nil -> nil
      suffix -> %{"@type" => "textEntityType#{suffix}"}
    end
  end

  defp service_action(%{"_" => type} = action) do
    detail =
      action |> Map.drop(["_"]) |> inspect(limit: 10, printable_limit: 200)

    String.replace_prefix(type, "MessageAction", "") <> " " <> detail
  end

  defp service_action(action),
    do: inspect(action, limit: 10, printable_limit: 200)
end
