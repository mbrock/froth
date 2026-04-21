defmodule Froth.Tools.PendingAskSupport do
  @moduledoc false

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Telegram.MessageIdSync
  alias Froth.Telegram.PendingAsks

  def session_config(%Context{} = ctx) do
    bc = ctx.bot_config || %{}

    %{
      "system" => ctx.system_prompt,
      "model" => Map.get(bc, :model),
      "tools" => ctx.tool_specs || [],
      "thinking" => Map.get(bc, :thinking) || %{},
      "effort" => Map.get(bc, :effort),
      "tool_timeout_ms" => nil
    }
  end

  def maybe_put_send_message_opt(keyword, _key, nil), do: keyword

  def maybe_put_send_message_opt(keyword, key, value),
    do: Keyword.put(keyword, key, value)

  def ask_reply_markup([]), do: nil

  def ask_reply_markup(alternatives) when is_list(alternatives) do
    rows =
      alternatives
      |> Enum.with_index()
      |> Enum.map(fn {alternative, index} ->
        [
          %{
            "@type" => "inlineKeyboardButton",
            "text" => alternative,
            "type" => %{
              "@type" => "inlineKeyboardButtonTypeCallback",
              "data" => Base.encode64("ask:#{index}")
            }
          }
        ]
      end)

    %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => rows
    }
  end

  def normalize_ask_alternatives(nil), do: {:ok, []}
  def normalize_ask_alternatives([]), do: {:ok, []}

  def normalize_ask_alternatives(alternatives) when is_list(alternatives) do
    alternatives
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {alternative, index}, {:ok, acc} when is_binary(alternative) ->
        trimmed = String.trim(alternative)

        if trimmed == "" do
          {:halt,
           {:error, "alternatives[#{index}] must be a non-empty string"}}
        else
          {:cont, {:ok, acc ++ [trimmed]}}
        end

      {_alternative, index}, _acc ->
        {:halt, {:error, "alternatives[#{index}] must be a string"}}
    end)
  end

  def normalize_ask_alternatives(_alternatives),
    do: {:error, "alternatives must be an array of strings"}

  def message_id(%{"id" => id}) when is_integer(id), do: {:ok, id}

  def message_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {message_id, ""} ->
        {:ok, message_id}

      _ ->
        {:error, "telegram send_message did not return a numeric message id"}
    end
  end

  def message_id(_sent),
    do: {:error, "telegram send_message did not return a message id"}

  def create_pending_ask(attrs, bot_id, chat_id, original_message_id)
      when is_map(attrs) and is_binary(bot_id) and is_integer(chat_id) and
             is_integer(original_message_id) do
    resolved_message_id =
      MessageIdSync.resolve(bot_id, chat_id, original_message_id)

    attrs =
      if is_integer(resolved_message_id) do
        Map.put(attrs, :message_id, resolved_message_id)
      else
        attrs
      end

    with {:ok, pending_ask} <- PendingAsks.create(attrs) do
      {:ok,
       maybe_refresh_pending_ask_message_id(
         pending_ask,
         bot_id,
         chat_id,
         original_message_id
       )}
    end
  end

  def format_error(%Ecto.Changeset{} = changeset),
    do: format_changeset_errors(changeset)

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  defp maybe_refresh_pending_ask_message_id(
         pending_ask,
         bot_id,
         chat_id,
         original_message_id
       )
       when is_map(pending_ask) and is_binary(bot_id) and is_integer(chat_id) and
              is_integer(original_message_id) do
    resolved_message_id =
      MessageIdSync.resolve(bot_id, chat_id, original_message_id)

    if is_integer(resolved_message_id) and
         resolved_message_id != pending_ask.message_id do
      PendingAsks.sync_message_id(
        bot_id,
        chat_id,
        pending_ask.message_id,
        resolved_message_id
      )

      %{pending_ask | message_id: resolved_message_id}
    else
      pending_ask
    end
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join(", ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end
end
