defmodule Froth.Telegram.Names do
  @moduledoc """
  Resolves Telegram user/chat IDs to display labels via TDLib,
  with per-process caching to avoid redundant calls within a request.
  """

  alias Froth.Telegram.Queries

  # ── public API ──────────────────────────────────────────────────

  @doc """
  Build a `%{sender_id => label}` map for the distinct senders in `messages`.
  Each message must have a `:sender_id` field.
  """
  def sender_label_map(messages, session_id) when is_list(messages) do
    messages
    |> ordered_sender_ids()
    |> Enum.take(80)
    |> Map.new(fn sender_id ->
      {sender_id, sender_label(sender_id, session_id)}
    end)
  end

  @doc """
  Resolve a single sender_id to a display label.
  Positive IDs are users, negative IDs are chats.
  """
  def sender_label(nil, _session_id), do: "unknown"

  def sender_label(sender_id, session_id) when is_integer(sender_id) and sender_id > 0 do
    cached({:user_label, session_id, sender_id}, fn ->
      case telegram_call(session_id, %{"@type" => "getUser", "user_id" => sender_id}) do
        {:ok, user} when is_map(user) -> format_user_label(user, sender_id)
        _ -> "user:#{sender_id}"
      end
    end)
  end

  def sender_label(sender_id, session_id) when is_integer(sender_id) do
    cached({:chat_sender_label, session_id, sender_id}, fn ->
      case telegram_call(session_id, %{"@type" => "getChat", "chat_id" => sender_id}) do
        {:ok, %{"title" => title}} when is_binary(title) and title != "" ->
          sanitize("#{title} (chat:#{sender_id})")

        _ ->
          "chat:#{sender_id}"
      end
    end)
  end

  @doc """
  Resolve a chat_id to its title.
  """
  def chat_name(chat_id, session_id) when is_integer(chat_id) do
    cached({:chat_name, session_id, chat_id}, fn ->
      case telegram_call(session_id, %{"@type" => "getChat", "chat_id" => chat_id}) do
        {:ok, %{"title" => title}} when is_binary(title) and title != "" ->
          sanitize(title)

        _ ->
          "chat:#{chat_id}"
      end
    end)
  end

  # ── process-dict cache ──────────────────────────────────────────

  defp cached(key, fun) do
    case Process.get(key) do
      nil ->
        value = fun.()
        Process.put(key, value)
        value

      value ->
        value
    end
  end

  # ── TDLib RPC ───────────────────────────────────────────────────

  defp telegram_call(session_id, request) when is_map(request) do
    session_id
    |> candidate_session_ids()
    |> Enum.reduce_while({:error, :no_session}, fn sid, _acc ->
      case safe_call(sid, request) do
        {:ok, _} = ok -> {:halt, ok}
        _ -> {:cont, {:error, :telegram_unavailable}}
      end
    end)
  end

  defp candidate_session_ids(session_id) when is_binary(session_id) and session_id != "" do
    [session_id | Queries.enabled_session_ids()]
    |> Enum.uniq()
  end

  defp candidate_session_ids(_), do: Queries.enabled_session_ids()

  defp safe_call(session_id, request)
       when is_binary(session_id) and session_id != "" and is_map(request) do
    try do
      Froth.Telegram.call(session_id, request, 5_000)
    rescue
      _ -> {:error, :telegram_unavailable}
    catch
      _, _ -> {:error, :telegram_unavailable}
    end
  end

  defp safe_call(_, _), do: {:error, :no_session}

  # ── formatting helpers ─────────────────────────────────────────

  defp format_user_label(user, user_id) when is_map(user) and is_integer(user_id) do
    case get_in(user, ["usernames", "active_usernames"]) do
      [u | _] when is_binary(u) and u != "" -> sanitize("@#{u}")
      _ -> "user:#{user_id}"
    end
  end

  defp sanitize(label) when is_binary(label) do
    label
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp ordered_sender_ids(messages) when is_list(messages) do
    {_, ids} =
      Enum.reduce(messages, {MapSet.new(), []}, fn msg, {seen, acc} ->
        sender_id = msg.sender_id

        cond do
          not is_integer(sender_id) -> {seen, acc}
          MapSet.member?(seen, sender_id) -> {seen, acc}
          true -> {MapSet.put(seen, sender_id), acc ++ [sender_id]}
        end
      end)

    ids
  end
end
