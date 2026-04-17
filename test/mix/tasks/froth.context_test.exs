defmodule Mix.Tasks.Froth.ContextTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.{Cycle, Message}
  alias Mix.Tasks.Froth.Context, as: FrothContextTask

  test "resolve_cycle_selector accepts latest shorthands" do
    assert FrothContextTask.resolve_cycle_selector("latest") == {:latest, 1}
    assert FrothContextTask.resolve_cycle_selector("latest:3") == {:latest, 3}
    assert FrothContextTask.resolve_cycle_selector("01KQABC") == {:id, "01KQABC"}
    assert FrothContextTask.resolve_cycle_selector("latest:0") == :error
    assert FrothContextTask.resolve_cycle_selector("latest:nope") == :error
  end

  test "render_cycle_request prints the exact assistant and user tool blocks" do
    cycle = %Cycle{
      id: "01KQTESTCYCLE00000000000000",
      status: :waiting_on_tools,
      provider: "anthropic",
      model: "claude-opus-4-6"
    }

    messages = [
      %Message{
        id: "msg_user",
        role: :user,
        content: [%{"type" => "text", "text" => "<msg message_id=\"4401\">hi</msg>"}]
      },
      %Message{
        id: "msg_assistant",
        role: :agent,
        content: [
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "search",
            "input" => %{"query" => ["froth", "context"]}
          }
        ]
      },
      %Message{
        id: "msg_tool_result",
        role: :user,
        content: [
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => "<shell task_id=\"shell:abc\">ok</shell>"
          }
        ]
      }
    ]

    rendered = FrothContextTask.render_cycle_request(cycle, messages)

    assert rendered =~ "cycle 01KQTESTCYCLE00000000000000 status=waiting_on_tools"
    assert rendered =~ "provider=anthropic"
    assert rendered =~ "model=claude-opus-4-6"
    assert rendered =~ "request_messages=3"
    assert rendered =~ "system_prompt=not_reconstructed"
    assert rendered =~ "[2] assistant id=msg_assistant"
    assert rendered =~ ~s("name" => "search")
    assert rendered =~ ~s("tool_use_id" => "call_1")
    assert rendered =~ ~s("<shell task_id=\\"shell:abc\\">ok</shell>")
  end

  test "render_cycle_requests joins multiple cycles in newest-first order" do
    newest = %Cycle{id: "01KQNEWEST0000000000000000", status: :completed}
    older = %Cycle{id: "01KQOLDER0000000000000000", status: :failed}

    rendered =
      FrothContextTask.render_cycle_requests([
        {newest,
         [%Message{id: "msg_new", role: :user, content: [%{"type" => "text", "text" => "new"}]}]},
        {older,
         [%Message{id: "msg_old", role: :user, content: [%{"type" => "text", "text" => "old"}]}]}
      ])

    newest_pos = :binary.match(rendered, "01KQNEWEST0000000000000000") |> elem(0)
    older_pos = :binary.match(rendered, "01KQOLDER0000000000000000") |> elem(0)

    assert newest_pos < older_pos
    assert rendered =~ String.duplicate("-", 80)
  end

  test "request_messages_for_cycle trims OpenAI history at the latest response boundary" do
    cycle = %Cycle{id: "01KQOPENAI0000000000000000", provider: "openai"}

    messages = [
      %Message{
        id: "msg_old_user",
        role: :user,
        content: [%{"type" => "text", "text" => "old user context"}]
      },
      %Message{
        id: "msg_boundary",
        role: :agent,
        metadata: %{"response_id" => "resp_123"},
        content: [
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "search",
            "input" => %{"query" => ["old"]}
          }
        ]
      },
      %Message{
        id: "msg_tool_result",
        role: :user,
        content: [
          %{
            "type" => "tool_result",
            "tool_use_id" => "call_1",
            "content" => "fresh tool result"
          }
        ]
      }
    ]

    {request_messages, previous_response_id} =
      FrothContextTask.request_messages_for_cycle(cycle, messages)

    assert previous_response_id == "resp_123"
    assert Enum.map(request_messages, & &1.id) == ["msg_tool_result"]

    rendered = FrothContextTask.render_cycle_request(cycle, messages)

    assert rendered =~ "request_messages=1 previous_response_id=resp_123"
    assert rendered =~ "fresh tool result"
    refute rendered =~ "old user context"
  end
end
