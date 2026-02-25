defmodule Froth.Inference.ToolSteps do
  @moduledoc """
  Query helpers for persisted inference-session tool steps.
  """

  alias Froth.Repo
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  @default_bot_id "charlie"

  @doc """
  Returns raw tool steps for a chat.

  This includes both completed and in-flight tool loop state persisted in
  `telegram_inference_sessions.tool_steps`.
  """
  @spec tool_steps_for_chat(integer(), integer() | keyword()) :: [map()]
  def tool_steps_for_chat(chat_id, limit_or_opts \\ 20) when is_integer(chat_id) do
    opts =
      cond do
        is_integer(limit_or_opts) ->
          [limit: parse_step_limit(limit_or_opts)]

        is_list(limit_or_opts) ->
          limit_or_opts

        true ->
          []
      end

    inference_session_id = opts[:inference_session_id]
    bot_id = opts[:bot_id] || @default_bot_id
    since = parse_history_timestamp(opts[:since] || opts[:from] || opts[:start])
    until = parse_history_timestamp(opts[:until] || opts[:to] || opts[:finish])

    step_limit = parse_step_limit(opts[:limit])

    inference_session_limit =
      if is_integer(inference_session_id) do
        1
      else
        parse_step_limit(opts[:inference_sessions_limit], 400)
      end

    Repo.all(
      build_inference_sessions_query(
        bot_id,
        chat_id,
        inference_session_id,
        since,
        until,
        inference_session_limit
      ),
      log: false
    )
    |> Enum.flat_map(fn inference_session ->
      (inference_session.tool_steps || [])
      |> Enum.reverse()
      |> Enum.map(fn step ->
        step
        |> Map.put("inference_session_id", inference_session.id)
        |> Map.put("inference_session_status", inference_session.status)
      end)
    end)
    |> Enum.filter(&step_in_time_window?(&1, since, until))
    |> Enum.sort_by(&(&1["at"] || ""), :desc)
    |> maybe_take_steps(step_limit)
  end

  defp step_in_time_window?(step, since, until) when is_map(step) do
    dt = parse_iso8601(step["at"])

    cond do
      dt == nil ->
        false

      since != nil and DateTime.compare(dt, since) == :lt ->
        false

      until != nil and DateTime.compare(dt, until) == :gt ->
        false

      true ->
        true
    end
  end

  defp step_in_time_window?(_, _, _), do: false

  defp maybe_take_steps(steps, nil), do: steps
  defp maybe_take_steps(steps, limit), do: Enum.take(steps, limit)

  defp parse_step_limit(nil, default), do: default
  defp parse_step_limit(value, _default) when is_integer(value), do: min(max(value, 1), 50_000)

  defp parse_step_limit(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> parse_step_limit(n, nil)
      _ -> nil
    end
  end

  defp parse_step_limit(_, _), do: nil
  defp parse_step_limit(value), do: parse_step_limit(value, nil)

  defp parse_history_timestamp(nil), do: nil

  defp parse_history_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
              {:ok, dt} -> dt
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp parse_history_timestamp(value) when is_integer(value) do
    cond do
      value > 9_999_999_999_999 ->
        from_unix_with_unit(value, :microsecond)

      value > 9_999_999_999 ->
        from_unix_with_unit(value, :millisecond)

      true ->
        from_unix_with_unit(value, :second)
    end
  end

  defp parse_history_timestamp(%DateTime{} = value), do: value

  defp parse_history_timestamp(%NaiveDateTime{} = value) do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_history_timestamp(%Date{} = value) do
    case DateTime.new(value, ~T[00:00:00], "Etc/UTC") do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_history_timestamp(_), do: nil

  defp from_unix_with_unit(value, unit) do
    case DateTime.from_unix(value, unit) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(_), do: nil

  defp build_inference_sessions_query(bot_id, chat_id, inference_session_id, since, until, limit) do
    base_query =
      from(c in InferenceSession,
        where: c.bot_id == ^bot_id and c.chat_id == ^chat_id,
        order_by: [desc: c.inserted_at],
        select: %{id: c.id, status: c.status, tool_steps: c.tool_steps}
      )

    query =
      if is_integer(inference_session_id) do
        from(c in base_query, where: c.id == ^inference_session_id)
      else
        base_query
      end

    query =
      if is_nil(since) do
        query
      else
        from(c in query, where: c.inserted_at >= ^since)
      end

    query =
      if is_nil(until) do
        query
      else
        from(c in query, where: c.inserted_at <= ^until)
      end

    case limit do
      value when is_integer(value) ->
        from(c in query, limit: ^value)

      _ ->
        query
    end
  end
end
