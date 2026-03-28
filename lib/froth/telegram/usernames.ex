defmodule Froth.Telegram.Usernames do
  @moduledoc false

  import Ecto.Query

  alias Froth.Repo
  alias Froth.Telegram.Queries
  alias Froth.Telegram.Username

  def get_label(user_id) when is_integer(user_id) and user_id > 0 do
    Repo.one(
      from(u in Username,
        where: u.user_id == ^user_id,
        select: u.label,
        limit: 1
      ),
      log: false
    )
  end

  def get_label(_user_id), do: nil

  def label_map(user_ids, session_id \\ nil)

  def label_map(user_ids, session_id) when is_list(user_ids) do
    user_ids = normalize_user_ids(user_ids)

    case user_ids do
      [] ->
        %{}

      _ ->
        persisted =
          Repo.all(
            from(u in Username,
              where: u.user_id in ^user_ids,
              select: {u.user_id, u.label}
            ),
            log: false
          )
          |> Map.new()

        missing_ids = Enum.reject(user_ids, &Map.has_key?(persisted, &1))

        fetched =
          missing_ids
          |> Task.async_stream(
            fn user_id -> {user_id, fetch_and_store_label(user_id, session_id)} end,
            ordered: false,
            max_concurrency: 8,
            timeout: :infinity
          )
          |> Enum.reduce(%{}, fn
            {:ok, {user_id, label}}, acc when is_binary(label) and label != "" ->
              Map.put(acc, user_id, label)

            _, acc ->
              acc
          end)

        Map.merge(persisted, fetched)
    end
  end

  def upsert_from_user(user, session_id \\ nil) when is_map(user) do
    user_id = user["id"]

    attrs = %{
      user_id: user_id,
      username: active_username(user),
      first_name: blank_to_nil(user["first_name"]),
      last_name: blank_to_nil(user["last_name"]),
      label: format_label(user),
      source_session_id: blank_to_nil(session_id)
    }

    if is_integer(user_id) and user_id > 0 do
      %Username{}
      |> Username.changeset(attrs)
      |> Repo.insert(
        on_conflict: [
          set: [
            username: attrs.username,
            first_name: attrs.first_name,
            last_name: attrs.last_name,
            label: attrs.label,
            source_session_id: attrs.source_session_id,
            updated_at: DateTime.utc_now()
          ]
        ],
        conflict_target: :user_id,
        log: false
      )
    else
      {:error, :invalid_user}
    end
  end

  def upsert_label(user_id, label, session_id \\ nil)
      when is_integer(user_id) and user_id > 0 and is_binary(label) and label != "" do
    attrs = %{user_id: user_id, label: label, source_session_id: blank_to_nil(session_id)}

    %Username{}
    |> Username.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          label: label,
          source_session_id: attrs.source_session_id,
          updated_at: DateTime.utc_now()
        ]
      ],
      conflict_target: :user_id,
      log: false
    )
  end

  def backfill_missing(opts \\ []) when is_list(opts) do
    session_id = resolve_session_id(Keyword.get(opts, :session_id))
    limit = normalize_limit(Keyword.get(opts, :limit))

    user_ids = missing_user_ids(limit)

    results =
      user_ids
      |> Task.async_stream(
        fn user_id -> {user_id, fetch_and_store_label(user_id, session_id)} end,
        ordered: false,
        max_concurrency: Keyword.get(opts, :max_concurrency, 8),
        timeout: :infinity
      )
      |> Enum.reduce(%{resolved: 0, failed: 0}, fn
        {:ok, {_user_id, label}}, acc when is_binary(label) and label != "" ->
          %{acc | resolved: acc.resolved + 1}

        _, acc ->
          %{acc | failed: acc.failed + 1}
      end)

    Map.merge(%{requested: length(user_ids), session_id: session_id}, results)
  end

  defp fetch_and_store_label(user_id, session_id) when is_integer(user_id) and user_id > 0 do
    fallback = "user:#{user_id}"

    case telegram_user(session_id, user_id) do
      {:ok, user} when is_map(user) ->
        _ = upsert_from_user(user, session_id)
        format_label(user)

      _ ->
        _ = upsert_label(user_id, fallback, session_id)
        fallback
    end
  end

  defp telegram_user(session_id, user_id) when is_integer(user_id) and user_id > 0 do
    session_id
    |> candidate_session_ids()
    |> Enum.reduce_while({:error, :no_session}, fn sid, _acc ->
      case safe_call(sid, %{"@type" => "getUser", "user_id" => user_id}) do
        {:ok, _user} = ok -> {:halt, ok}
        _ -> {:cont, {:error, :telegram_unavailable}}
      end
    end)
  end

  defp candidate_session_ids(session_id) when is_binary(session_id) and session_id != "" do
    [session_id | Queries.enabled_session_ids()]
    |> Enum.uniq()
  end

  defp candidate_session_ids(_) do
    Queries.enabled_session_ids()
  end

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

  defp resolve_session_id(session_id) when is_binary(session_id) and session_id != "" do
    session_id
  end

  defp resolve_session_id(_session_id) do
    Queries.default_user_session_id() || Queries.default_session_id()
  end

  defp missing_user_ids(limit) when is_integer(limit) and limit > 0 do
    Repo.all(
      from(m in "telegram_messages",
        left_join: u in Username,
        on: u.user_id == m.sender_id,
        where: not is_nil(m.sender_id) and m.sender_id > 0 and is_nil(u.user_id),
        distinct: m.sender_id,
        order_by: [asc: m.sender_id],
        select: m.sender_id,
        limit: ^limit
      ),
      log: false
    )
  end

  defp missing_user_ids(_limit) do
    Repo.all(
      from(m in "telegram_messages",
        left_join: u in Username,
        on: u.user_id == m.sender_id,
        where: not is_nil(m.sender_id) and m.sender_id > 0 and is_nil(u.user_id),
        distinct: m.sender_id,
        order_by: [asc: m.sender_id],
        select: m.sender_id
      ),
      log: false
    )
  end

  defp normalize_user_ids(user_ids) do
    user_ids
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_limit), do: nil

  defp active_username(user) when is_map(user) do
    case get_in(user, ["usernames", "active_usernames"]) do
      [username | _] when is_binary(username) and username != "" -> username
      _ -> nil
    end
  end

  defp format_label(user) when is_map(user) do
    case active_username(user) do
      username when is_binary(username) and username != "" -> "@#{username}"
      _ -> "user:#{user["id"]}"
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
