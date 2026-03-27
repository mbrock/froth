defmodule Froth.Telegram.MessageIdSync do
  @moduledoc false

  @table :froth_telegram_message_id_sync
  @ttl_ms 300_000

  def put(bot_id, chat_id, old_message_id, new_message_id)
      when is_binary(bot_id) and is_integer(chat_id) and is_integer(old_message_id) and
             is_integer(new_message_id) do
    ensure_table!()

    :ets.insert(
      @table,
      {{bot_id, chat_id, old_message_id}, {new_message_id, System.monotonic_time(:millisecond)}}
    )

    :ok
  end

  def put(_bot_id, _chat_id, _old_message_id, _new_message_id), do: :ok

  def resolve(bot_id, chat_id, message_id)
      when is_binary(bot_id) and is_integer(chat_id) and is_integer(message_id) do
    ensure_table!()

    case :ets.lookup(@table, {bot_id, chat_id, message_id}) do
      [{{^bot_id, ^chat_id, ^message_id}, {resolved_message_id, inserted_at}}] ->
        if System.monotonic_time(:millisecond) - inserted_at <= @ttl_ms do
          resolved_message_id
        else
          :ets.delete(@table, {bot_id, chat_id, message_id})
          message_id
        end

      _ ->
        message_id
    end
  end

  def resolve(_bot_id, _chat_id, message_id), do: message_id

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @table
        end

      _tid ->
        @table
    end
  end
end
