defmodule Froth.Tasks.EvalSessionsTest do
  use ExUnit.Case, async: true

  alias Froth.Tasks.EvalSessions

  describe "ensure_session/1 and binding persistence" do
    test "creates a new random session when session_id is omitted" do
      {session_id, created?} = EvalSessions.ensure_session(nil)

      assert created?
      assert is_binary(session_id)
      assert String.starts_with?(session_id, "eval_session_")
      assert EvalSessions.binding(session_id) == []
    end

    test "creates then reuses a provided session_id" do
      session_id = "eval_session_manual_test_#{System.unique_integer([:positive])}"

      assert {^session_id, true} = EvalSessions.ensure_session(session_id)
      assert {^session_id, false} = EvalSessions.ensure_session(session_id)
    end

    test "stores and reads bindings per session" do
      {session_id, _created?} = EvalSessions.ensure_session(nil)
      :ok = EvalSessions.put_binding(session_id, a: 1)

      assert EvalSessions.binding(session_id) == [a: 1]
    end
  end
end
