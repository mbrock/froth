defmodule Froth.AgentInspectTest do
  use ExUnit.Case, async: true

  alias Froth.AgentInspect

  test "summarizes breakpoints and tail rows from a stored request payload" do
    payload = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => "<chapter name=\"ch01\">one</chapter>"
            },
            %{
              "type" => "text",
              "text" => "<chapter name=\"ch02\">two</chapter>",
              "cache_control" => %{"type" => "ephemeral"}
            },
            %{
              "type" => "text",
              "text" => "<msg message_id=\"1\">hello</msg>"
            },
            %{
              "type" => "text",
              "text" => "<msg message_id=\"2\">world</msg>"
            },
            %{
              "type" => "text",
              "text" => "<info>chat info</info>",
              "cache_control" => %{"type" => "ephemeral"}
            }
          ]
        }
      ]
    }

    summary = AgentInspect.request_summary_from_payload(payload, 3)

    assert summary.content_length == 5

    assert summary.breakpoints == [
             %{idx: 1, label: "<chapter ch02>"},
             %{idx: 4, label: "<info>"}
           ]

    assert summary.tail == [
             %{idx: 2, cache_control?: false, label: "1"},
             %{idx: 3, cache_control?: false, label: "2"},
             %{idx: 4, cache_control?: true, label: "<info>"}
           ]
  end
end
