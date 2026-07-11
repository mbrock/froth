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
    session_id =
      "s_test_" <>
        Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    previous_executable = System.get_env("CODEX_EXECUTABLE")
    System.put_env("CODEX_EXECUTABLE", "/definitely/not-a-real-codex")

    on_exit(fn ->
      if is_binary(previous_executable) do
        System.put_env("CODEX_EXECUTABLE", previous_executable)
      else
        System.delete_env("CODEX_EXECUTABLE")
      end
    end)

    pid = start_supervised!({Session, session_id: session_id, boot: false})

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
           ] =
             Enum.map(
               snapshot.entries,
               &Map.take(&1, [:id, :body, :sequence])
             )

    send_assistant_completed(pid, "turn-1", "msg-2", "second")

    assert {:ok, snapshot} = Session.snapshot(session_id)

    assert [
             %{id: "assistant-turn-1-msg-1", body: "first", sequence: 1},
             %{id: "assistant-turn-1-msg-2", body: "second", sequence: 2}
           ] =
             Enum.map(
               snapshot.entries,
               &Map.take(&1, [:id, :body, :sequence])
             )
  end

  test "close/1 terminates a dynamically supervised session without restarting it" do
    session_id =
      "s_test_" <>
        Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    previous_executable = System.get_env("CODEX_EXECUTABLE")
    System.put_env("CODEX_EXECUTABLE", "/definitely/not-a-real-codex")

    :ok = Phoenix.PubSub.subscribe(Froth.PubSub, "events")

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(Froth.PubSub, "events")

      if is_binary(previous_executable) do
        System.put_env("CODEX_EXECUTABLE", previous_executable)
      else
        System.delete_env("CODEX_EXECUTABLE")
      end
    end)

    assert {:ok, pid} =
             DynamicSupervisor.start_child(
               Froth.Codex.SessionSupervisor,
               {Session, session_id: session_id, boot: false}
             )

    _ = :sys.get_state(pid)
    ref = Process.monitor(pid)
    span_id = Session.span_id(session_id)

    assert is_binary(span_id)

    assert_receive {:event,
                    %Froth.Event{
                      event: "froth.codex.session.start",
                      span_id: ^span_id,
                      parent_id: nil,
                      metadata: %{"session_id" => ^session_id}
                    }}

    assert :ok = Session.close(session_id)

    assert_receive {:event,
                    %Froth.Event{
                      event: "froth.codex.session.close_requested",
                      parent_id: ^span_id,
                      metadata: %{"session_id" => ^session_id}
                    }}

    assert_receive {:event,
                    %Froth.Event{
                      event: "froth.codex.session.stop",
                      span_id: ^span_id,
                      metadata: %{
                        "session_id" => ^session_id,
                        "reason" => "requested"
                      }
                    }}

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    assert Session.child_spec(session_id: session_id).restart == :transient

    refute_receive {:event,
                    %Froth.Event{
                      event: "froth.codex.session.start",
                      metadata: %{"session_id" => ^session_id}
                    }},
                   100

    assert :ok = Session.close(session_id)
  end

  test "shared app-server notifications are routed to their owning thread" do
    first_id = "s_test_route_#{System.unique_integer([:positive])}"
    second_id = "s_test_route_#{System.unique_integer([:positive])}"
    first = start_supervised!({Session, session_id: first_id, boot: false})
    second = start_supervised!({Session, session_id: second_id, boot: false})

    set_thread_state(first, first_id, "thr_first", "turn_first")
    set_thread_state(second, second_id, "thr_second", "turn_second")

    notification =
      {:codex, :notification, "item/agentMessage/delta",
       %{
         "threadId" => "thr_first",
         "turnId" => "turn_first",
         "itemId" => "message-first",
         "delta" => "only first"
       }, %{}, nil}

    send(first, notification)
    send(second, notification)
    _ = :sys.get_state(first)
    _ = :sys.get_state(second)

    assert {:ok, %{entries: [%{body: "only first"}]}} =
             Session.snapshot(first_id)

    assert {:ok, %{entries: []}} = Session.snapshot(second_id)
    assert :ok = Session.close(first_id)
    assert :ok = Session.close(second_id)
  end

  defp set_thread_state(pid, session_id, thread_id, turn_id) do
    :sys.replace_state(pid, fn state ->
      state
      |> Map.merge(%{
        session_id: session_id,
        status: :ready,
        thread_id: thread_id,
        active_turn_id: turn_id,
        active_turn_started_at_ms: nil,
        active_assistant_entry_id: nil,
        active_assistant_text: "",
        active_reasoning_entry_id: nil,
        active_reasoning_text: "",
        tool_entry_ids_by_call: %{},
        entry_seq: 0,
        entries: []
      })
    end)
  end

  defp send_assistant_delta(pid, turn_id, item_id, delta) do
    send(
      pid,
      {:codex, :notification, "item/agentMessage/delta",
       %{"turnId" => turn_id, "itemId" => item_id, "delta" => delta}, %{},
       nil}
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
