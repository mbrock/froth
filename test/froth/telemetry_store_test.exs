defmodule Froth.Telemetry.StoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Froth.{Event, Repo}

  setup do
    owner = Sandbox.start_owner!(Repo, shared: false)
    Sandbox.allow(Repo, owner, Process.whereis(Froth.Telemetry.Store))

    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "persists events as soon as they are handled" do
    span_id = "span-#{System.unique_integer([:positive])}"

    :ok =
      Froth.Telemetry.Store.handle_event(
        [:froth, :agent, :tool, :completed],
        %{duration_ms: 17},
        %{span_id: span_id, parent_id: "parent-1", tool_name: "shell"},
        nil
      )

    _state = :sys.get_state(Froth.Telemetry.Store)

    event =
      Repo.one!(
        from(e in Event,
          where:
            e.event == "froth.agent.tool.completed" and e.span_id == ^span_id
        )
      )

    assert event.event == "froth.agent.tool.completed"
    assert event.span_id == span_id
    assert event.parent_id == "parent-1"
    assert event.measurements == %{"duration_ms" => 17}
    assert event.metadata["tool_name"] == "shell"
  end
end
