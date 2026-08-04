defmodule Froth.Telegram.BotAdapter do
  @moduledoc """
  Telegram transport adapter for bot workers.

  This module contains Telegram-specific concerns such as mention/access checks
  and message send/edit helpers.
  """

  @text_limit 4096

  @doc "Telegram's hard per-message text limit in UTF-16 code units. Exposed for callers that want to chunk proactively."
  def text_limit, do: @text_limit

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(
      Froth.PubSub,
      Froth.Telegram.Session.topic(session_id)
    )
  end

  @doc """
  Split a long text into chunks of at most `@text_limit` characters, preferring
  paragraph (`"\\n\\n"`) and line (`"\\n"`) boundaries over hard cuts.
  """
  def split_long_text(text) when is_binary(text),
    do: split_long_text(text, @text_limit)

  def split_long_text(text, limit)
      when is_binary(text) and is_integer(limit) and limit > 0 do
    if String.length(text) <= limit do
      [text]
    else
      do_split_text(text, limit, [])
    end
  end

  defp do_split_text("", _limit, acc), do: Enum.reverse(acc)

  defp do_split_text(text, limit, acc) do
    if String.length(text) <= limit do
      Enum.reverse([text | acc])
    else
      candidate = String.slice(text, 0, limit)

      split_pos =
        case :binary.matches(candidate, "\n\n") |> List.last() do
          {pos, _len} when pos > div(limit, 4) ->
            pos + 2

          _ ->
            case :binary.matches(candidate, "\n") |> List.last() do
              {pos, _len} when pos > div(limit, 4) -> pos + 1
              _ -> limit
            end
        end

      {chunk, rest} = String.split_at(text, split_pos)

      do_split_text(String.trim_leading(rest), limit, [
        String.trim_trailing(chunk) | acc
      ])
    end
  end

  def mentioned?(msg, bot_username, bot_user_id)
      when is_map(msg) and is_binary(bot_username) and is_integer(bot_user_id) do
    text = get_in(msg, ["content", "text", "text"]) || ""
    entities = get_in(msg, ["content", "text", "entities"]) || []

    String.contains?(text, "@#{bot_username}") or
      Enum.any?(entities, fn e ->
        e["type"]["@type"] == "textEntityTypeMention" and
          String.contains?(
            String.slice(text, e["offset"], e["length"]),
            bot_username
          )
      end) or
      Enum.any?(entities, fn e ->
        e["type"]["@type"] == "textEntityTypeMentionName" and
          e["type"]["user_id"] == bot_user_id
      end)
  end

  def mentioned?(_, _, _), do: false

  def mentioned?(msg, bot_username, bot_user_id, name_triggers)
      when is_map(msg) and is_binary(bot_username) and is_integer(bot_user_id) and
             is_list(name_triggers) do
    text = get_in(msg, ["content", "text", "text"]) || ""

    mentioned?(msg, bot_username, bot_user_id) or
      name_triggered?(msg, name_triggers) or
      (charlie_trigger?(name_triggers) and
         fuzzy_name_match?(text, "charlie", 2))
  end

  defp charlie_trigger?(name_triggers) when is_list(name_triggers) do
    Enum.any?(name_triggers, &(String.downcase(&1) == "charlie"))
  end

  defp name_triggered?(msg, triggers) when is_list(triggers) do
    text = get_in(msg, ["content", "text", "text"]) || ""
    downcased = String.downcase(text)

    Enum.any?(triggers, fn trigger ->
      t = String.downcase(trigger)
      # Use word boundary for short triggers (< 15 chars) to avoid
      # "charlie" matching inside "captaincharliekirkbot"
      if String.length(t) < 15 do
        Regex.match?(~r/\b#{Regex.escape(t)}\b/, downcased)
      else
        String.contains?(downcased, t)
      end
    end)
  end

  # Levenshtein edit distance for fuzzy name matching (Patty's typos)
  defp levenshtein(s, t) when is_binary(s) and is_binary(t) do
    s_graphemes = String.graphemes(s)
    t_graphemes = String.graphemes(t)
    s_len = length(s_graphemes)
    t_len = length(t_graphemes)

    if s_len == 0 do
      t_len
    else
      if t_len == 0 do
        s_len
      else
        # Build matrix row by row
        first_row = Enum.to_list(0..t_len)

        Enum.reduce(Enum.with_index(s_graphemes, 1), first_row, fn {s_char, i},
                                                                   prev_row ->
          Enum.reduce(
            Enum.with_index(t_graphemes, 1),
            {[i], i - 1},
            fn {t_char, j}, {row, diag} ->
              cost = if s_char == t_char, do: 0, else: 1

              val =
                min(
                  min(List.last(row) + 1, Enum.at(prev_row, j) + 1),
                  diag + cost
                )

              {row ++ [val], Enum.at(prev_row, j)}
            end
          )
          |> elem(0)
        end)
        |> List.last()
      end
    end
  end

  defp fuzzy_name_match?(text, name, max_distance) do
    words = String.split(String.downcase(text), ~r/[^a-z]+/, trim: true)
    target = String.downcase(name)

    Enum.any?(words, fn word ->
      # Only check words roughly the right length to avoid wasting time
      abs(String.length(word) - String.length(target)) <= max_distance and
        levenshtein(word, target) <= max_distance
    end)
  end

  # Allow DMs from owner or any explicitly allowed user
  # Mikael, Daniel, John Sherman
  @allowed_dm_users [
    362_441_422,
    1_635_262_887,
    7_986_089_238,
    8_564_331_819,
    6_071_676_050
  ]

  def allowed_chat?(chat_id, owner_user_id, _session_id)
      when is_integer(chat_id) and is_integer(owner_user_id) and chat_id > 0 do
    chat_id in @allowed_dm_users
  end

  def allowed_chat?(chat_id, owner_user_id, session_id)
      when is_integer(chat_id) and is_integer(owner_user_id) and
             is_binary(session_id) do
    cache_key = {:chat_allowed, session_id, chat_id, owner_user_id}

    case Process.get(cache_key) do
      nil ->
        allowed =
          case Froth.Telegram.call(session_id, %{
                 "@type" => "getChatMember",
                 "chat_id" => chat_id,
                 "member_id" => %{
                   "@type" => "messageSenderUser",
                   "user_id" => owner_user_id
                 }
               }) do
            {:ok, %{"status" => %{"@type" => status}}}
            when status in [
                   "chatMemberStatusCreator",
                   "chatMemberStatusAdministrator",
                   "chatMemberStatusMember"
                 ] ->
              true

            _ ->
              false
          end

        Process.put(cache_key, allowed)

        Span.execute(
          [:froth, :telegram, :bot_adapter, :chat_access_check],
          nil,
          %{chat_id: chat_id, allowed: allowed}
        )

        allowed

      allowed ->
        allowed
    end
  end

  def send_message(session_id, chat_id, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and is_binary(text) and
             is_list(opts) do
    formatted_text = plain_formatted_text(text, opts[:entities])
    send_formatted_message(session_id, chat_id, formatted_text, opts)
  end

  def send_markdown(session_id, chat_id, reply_to, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and is_binary(text) and
             is_list(opts) do
    opts = Keyword.put(opts, :reply_to, reply_to)

    case parse_markdown(session_id, text) do
      {:ok, %{} = formatted_text} ->
        send_formatted_message(session_id, chat_id, formatted_text, opts)

      {:error, _reason} = error ->
        error
    end
  end

  def edit_message_text(session_id, chat_id, message_id, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and
             is_integer(message_id) and
             is_binary(text) and is_list(opts) do
    formatted_text = plain_formatted_text(text, opts[:entities])

    edit_formatted_message(
      session_id,
      chat_id,
      message_id,
      formatted_text,
      opts
    )
  end

  def edit_message_markdown(session_id, chat_id, message_id, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and
             is_integer(message_id) and
             is_binary(text) and is_list(opts) do
    case parse_markdown(session_id, text) do
      {:ok, %{} = formatted_text} ->
        formatted_text =
          case opts[:plain_suffix] do
            suffix when is_binary(suffix) ->
              Map.update!(formatted_text, "text", &(&1 <> suffix))

            _ ->
              formatted_text
          end

        edit_formatted_message(
          session_id,
          chat_id,
          message_id,
          formatted_text,
          opts
        )

      {:error, _reason} = error ->
        error
    end
  end

  def edit_message_italic(session_id, chat_id, message_id, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and
             is_integer(message_id) and
             is_binary(text) and is_list(opts) do
    entities =
      [
        %{
          "@type" => "textEntity",
          "offset" => 0,
          "length" => String.length(text),
          "type" => %{"@type" => "textEntityTypeItalic"}
        }
      ]

    edit_message_text(
      session_id,
      chat_id,
      message_id,
      text,
      Keyword.put(opts, :entities, entities)
    )
  end

  def send_error(session_id, chat_id, message)
      when is_binary(session_id) and is_integer(chat_id) and
             is_binary(message) do
    text = "ERROR: #{message}"

    send_message(session_id, chat_id, text,
      entities: [
        %{
          "@type" => "textEntity",
          "offset" => 0,
          "length" => String.length(text),
          "type" => %{"@type" => "textEntityTypeBold"}
        }
      ]
    )
  end

  def send_italic(session_id, chat_id, reply_to, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and is_binary(text) and
             is_list(opts) do
    italic = [
      %{
        "@type" => "textEntity",
        "offset" => 0,
        "length" => String.length(text),
        "type" => %{"@type" => "textEntityTypeItalic"}
      }
    ]

    send_message(
      session_id,
      chat_id,
      text,
      opts
      |> Keyword.put(:reply_to, reply_to)
      |> Keyword.put(:entities, italic)
    )
  end

  @doc "Send a visibly attributed block quote, optionally replying to a message."
  def send_blockquote(session_id, chat_id, reply_to, label, text, opts \\ [])
      when is_binary(session_id) and is_integer(chat_id) and
             is_binary(label) and is_binary(text) and is_list(opts) do
    body = String.trim(text)
    formatted = "#{label}\n#{body}"
    body_offset = utf16_length(label <> "\n")

    entities = [
      %{
        "@type" => "textEntity",
        "offset" => 0,
        "length" => utf16_length(label),
        "type" => %{"@type" => "textEntityTypeBold"}
      },
      %{
        "@type" => "textEntity",
        "offset" => body_offset,
        "length" => utf16_length(body),
        "type" => %{"@type" => "textEntityTypeBlockQuote"}
      }
    ]

    send_message(
      session_id,
      chat_id,
      formatted,
      opts
      |> Keyword.put(:reply_to, reply_to)
      |> Keyword.put(:entities, entities)
    )
  end

  def send_typing(session_id, chat_id)
      when is_binary(session_id) and is_integer(chat_id) do
    Froth.Telegram.send(session_id, %{
      "@type" => "sendChatAction",
      "chat_id" => chat_id,
      "action" => %{"@type" => "chatActionTyping"}
    })
  end

  def answer_callback(session_id, callback_query_id)
      when is_binary(session_id) and
             (is_binary(callback_query_id) or is_integer(callback_query_id)) do
    case normalize_int64(callback_query_id) do
      nil ->
        {:error, :invalid_callback_query_id}

      normalized_id ->
        Froth.Telegram.send(session_id, %{
          "@type" => "answerCallbackQuery",
          "callback_query_id" => normalized_id
        })
    end
  end

  def answer_callback_with_url(session_id, callback_query_id, url)
      when is_binary(session_id) and
             (is_binary(callback_query_id) or is_integer(callback_query_id)) and
             is_binary(url) do
    case normalize_int64(callback_query_id) do
      nil ->
        {:error, :invalid_callback_query_id}

      normalized_id ->
        Froth.Telegram.send(session_id, %{
          "@type" => "answerCallbackQuery",
          "callback_query_id" => normalized_id,
          "url" => url
        })
    end
  end

  defp edit_formatted_message(
         session_id,
         chat_id,
         message_id,
         formatted_text,
         opts
       )
       when is_binary(session_id) and is_integer(chat_id) and
              is_integer(message_id) and
              is_map(formatted_text) and is_list(opts) do
    payload = %{
      "@type" => "editMessageText",
      "chat_id" => chat_id,
      "message_id" => message_id,
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => formatted_text
      }
    }

    payload =
      case opts[:reply_markup] do
        markup when is_map(markup) -> Map.put(payload, "reply_markup", markup)
        _ -> payload
      end

    session_id
    |> Froth.Telegram.call(payload)
    |> normalize_tdlib_result()
  end

  defp send_formatted_message(session_id, chat_id, formatted_text, opts)
       when is_binary(session_id) and is_integer(chat_id) and
              is_map(formatted_text) and
              is_list(opts) do
    payload = %{
      "@type" => "sendMessage",
      "chat_id" => chat_id,
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => formatted_text
      }
    }

    payload =
      case reply_to_msg(opts[:reply_to]) do
        reply_to when is_map(reply_to) ->
          Map.put(payload, "reply_to", reply_to)

        _ ->
          payload
      end

    payload =
      case opts[:reply_markup] do
        markup when is_map(markup) -> Map.put(payload, "reply_markup", markup)
        _ -> payload
      end

    session_id
    |> Froth.Telegram.call(payload)
    |> normalize_tdlib_result()
  end

  defp plain_formatted_text(text, entities) when is_binary(text) do
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

  defp parse_markdown(session_id, text)
       when is_binary(session_id) and is_binary(text) do
    with {:ok, html} <- Froth.Telegram.Markdown.to_telegram_html(text) do
      session_id
      |> Froth.Telegram.call(%{
        "@type" => "parseTextEntities",
        "text" => html,
        "parse_mode" => %{"@type" => "textParseModeHTML"}
      })
      |> normalize_tdlib_result()
    end
  end

  defp reply_to_msg(nil), do: nil
  defp reply_to_msg(0), do: nil

  defp reply_to_msg(message_id)
       when is_integer(message_id) and message_id > 0 do
    %{"@type" => "inputMessageReplyToMessage", "message_id" => message_id}
  end

  defp utf16_length(text) when is_binary(text) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp normalize_int64(value) when is_integer(value),
    do: Integer.to_string(value)

  defp normalize_int64(""), do: nil
  defp normalize_int64(value) when is_binary(value), do: value
  defp normalize_int64(_value), do: nil

  defp normalize_tdlib_result(
         {:ok, %{"@type" => "error", "message" => message}}
       )
       when is_binary(message) do
    {:error, message}
  end

  defp normalize_tdlib_result({:ok, %{"@type" => "error"} = error}) do
    {:error, inspect(error)}
  end

  defp normalize_tdlib_result(result), do: result
end
