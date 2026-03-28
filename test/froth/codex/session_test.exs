defmodule Froth.Codex.SessionTest do
  use ExUnit.Case, async: false

  alias Froth.Codex.Session
  alias Froth.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "assistant deltas for a new item do not append onto the previous assistant entry" do
    session_id = "s_test_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    previous_executable = System.get_env("CODEX_EXECUTABLE")
    System.put_env("CODEX_EXECUTABLE", "/definitely/not-a-real-codex")

    on_exit(fn ->
      if is_binary(previous_executable) do
        System.put_env("CODEX_EXECUTABLE", previous_executable)
      else
        System.delete_env("CODEX_EXECUTABLE")
      end
    end)

    pid = start_supervised!({Session, session_id: session_id})

    assert {:ok, _snapshot} = Session.snapshot(session_id)

    :sys.replace_state(pid, fn _state ->
      %{
        session_id: session_id,
        codex_pid: nil,
        codex_topic: "codex:wire:#{session_id}",
        status: :ready,
        thread_id: "thread-1",
        active_turn_id: "turn-1",
        active_turn_started_at_ms: nil,
        last_turn_elapsed_ms: nil,
        active_assistant_entry_id: nil,
        active_assistant_text: "",
        active_reasoning_entry_id: nil,
        active_reasoning_text: "",
        tool_entry_ids_by_call: %{},
        available_models_checked?: false,
        token_usage: nil,
        rate_limits: nil,
        auth: nil,
        runtime: nil,
        available_models: [],
        seen_misc_methods: MapSet.new(),
        entry_seq: 0,
        entries: []
      }
    end)

    send_assistant_delta(pid, "turn-1", "msg-1", "first")
    send_assistant_completed(pid, "turn-1", "msg-1", "first")
    send_assistant_delta(pid, "turn-1", "msg-2", "second")

    assert {:ok, snapshot} = Session.snapshot(session_id)

    assert [
             %{id: "assistant-turn-1-msg-1", body: "first", sequence: 1},
             %{id: "assistant-turn-1-msg-2", body: "second", sequence: 2}
           ] = Enum.map(snapshot.entries, &Map.take(&1, [:id, :body, :sequence]))

    send_assistant_completed(pid, "turn-1", "msg-2", "second")

    assert {:ok, snapshot} = Session.snapshot(session_id)

    assert [
             %{id: "assistant-turn-1-msg-1", body: "first", sequence: 1},
             %{id: "assistant-turn-1-msg-2", body: "second", sequence: 2}
           ] = Enum.map(snapshot.entries, &Map.take(&1, [:id, :body, :sequence]))
  end

  defp send_assistant_delta(pid, turn_id, item_id, delta) do
    send(
      pid,
      {:codex, :notification, "item/agentMessage/delta",
       %{"turnId" => turn_id, "itemId" => item_id, "delta" => delta}, %{}, nil}
    )

    _ = :sys.get_state(pid)
    :ok
  end

  defp send_assistant_completed(pid, turn_id, item_id, text) do
    send(
      pid,
      {:codex, :notification, "item/completed",
       %{
         "turnId" => turn_id,
         "item" => %{
           "id" => item_id,
           "type" => "agentMessage",
           "content" => [%{"type" => "text", "text" => text}]
         }
       }, %{}, nil}
    )

    _ = :sys.get_state(pid)
    :ok
  end
end
