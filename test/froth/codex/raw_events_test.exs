defmodule Froth.Codex.RawEventsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Froth.Codex.RawEvent
  alias Froth.Codex.RawEvents
  alias Froth.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "append_notification persists raw notification payload" do
    session_id = "s_raw_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    method = "thread/started"
    params = %{"threadId" => "thr_test", "source" => "test"}
    raw_message = %{"method" => method, "params" => params}
    raw_line = Jason.encode!(raw_message)

    assert :ok = RawEvents.append_notification(session_id, method, params, raw_message, raw_line)

    event = latest_raw_event!(session_id)

    assert event.kind == "notification"
    assert event.method == method
    assert event.raw_line == raw_line
    assert event.payload["params"] == params
    assert event.payload["raw_message"] == raw_message
    assert %DateTime{} = event.received_at
  end

  test "append_protocol_error persists protocol error payload" do
    session_id = "s_raw_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    reason = {:invalid_json, "not-json", "decode error"}

    assert :ok = RawEvents.append_protocol_error(session_id, reason, "not-json")

    event = latest_raw_event!(session_id)

    assert event.kind == "protocol_error"
    assert is_nil(event.method)
    assert event.raw_line == "not-json"
    assert is_binary(event.payload["reason"])
    assert String.contains?(event.payload["reason"], "invalid_json")
  end

  defp latest_raw_event!(session_id) do
    from(e in RawEvent,
      where: e.session_id == ^session_id,
      order_by: [desc: e.id],
      limit: 1
    )
    |> Repo.one!()
  end
end
