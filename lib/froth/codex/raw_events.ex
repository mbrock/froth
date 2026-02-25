defmodule Froth.Codex.RawEvents do
  @moduledoc """
  Append-only persistence for raw Codex wire events.

  This stores notification payloads before they are interpreted into the
  rendered session timeline, so we can reprocess parser logic later without
  losing original event data.
  """

  import Ecto.Query
  require Logger

  alias Froth.Codex.RawEvent
  alias Froth.Repo

  @spec append_notification(String.t(), String.t(), map(), term(), String.t() | nil) :: :ok
  def append_notification(session_id, method, params, raw_message, raw_line \\ nil)
      when is_binary(session_id) and is_binary(method) and is_map(params) do
    payload = %{
      "params" => params,
      "raw_message" => normalize_raw_message(raw_message)
    }

    append(session_id, "notification", method, payload, raw_line)
  end

  @spec append_protocol_error(String.t(), term(), String.t() | nil) :: :ok
  def append_protocol_error(session_id, reason, raw_line \\ nil) when is_binary(session_id) do
    payload = %{
      "reason" => inspect(reason, limit: 120, printable_limit: 10_000)
    }

    append(session_id, "protocol_error", nil, payload, raw_line)
  end

  @spec list_recent(String.t(), pos_integer()) :: [RawEvent.t()]
  def list_recent(session_id, limit \\ 200)
      when is_binary(session_id) and is_integer(limit) and limit > 0 do
    from(e in RawEvent,
      where: e.session_id == ^session_id,
      order_by: [desc: e.id],
      limit: ^limit
    )
    |> Repo.all(log: false)
    |> Enum.reverse()
  rescue
    error ->
      Logger.warning(
        event: :codex_raw_events_list_failed,
        session_id: session_id,
        error: Exception.message(error)
      )

      []
  end

  defp append(session_id, kind, method, payload, raw_line)
       when is_binary(session_id) and is_binary(kind) and is_map(payload) do
    attrs = %{
      session_id: session_id,
      kind: kind,
      method: normalize_optional_text(method),
      payload: payload,
      raw_line: normalize_raw_line(raw_line),
      received_at: DateTime.utc_now()
    }

    case %RawEvent{}
         |> RawEvent.changeset(attrs)
         |> Repo.insert(log: false) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          event: :codex_raw_events_append_failed,
          session_id: session_id,
          kind: kind,
          method: method,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        event: :codex_raw_events_append_failed,
        session_id: session_id,
        kind: kind,
        method: method,
        error: Exception.message(error)
      )

      :ok
  end

  defp normalize_raw_message(raw_message) when is_map(raw_message), do: raw_message

  defp normalize_raw_message(raw_message) do
    %{"value" => inspect(raw_message, limit: 120, printable_limit: 10_000)}
  end

  defp normalize_raw_line(raw_line) when is_binary(raw_line), do: raw_line
  defp normalize_raw_line(_raw_line), do: ""

  defp normalize_optional_text(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_text(_value), do: nil
end
