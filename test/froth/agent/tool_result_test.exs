defmodule Froth.Agent.ToolResultTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.ToolResult

  test "to_api preserves structured content blocks with string keys" do
    result =
      ToolResult.new("call_1", [
        %{"type" => "text", "text" => "done"},
        %{
          type: "image",
          source: %{
            type: "base64",
            media_type: "image/png",
            data: "aGVsbG8="
          }
        }
      ])

    assert ToolResult.to_api(result) == %{
             "type" => "tool_result",
             "tool_use_id" => "call_1",
             "content" => [
               %{"type" => "text", "text" => "done"},
               %{
                 "type" => "image",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "image/png",
                   "data" => "aGVsbG8="
                 }
               }
             ]
           }
  end
end
