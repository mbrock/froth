defmodule Froth.LLM.MessageTest do
  use ExUnit.Case, async: true

  alias Froth.LLM.Message

  test "normalizes maps and stringifies block keys" do
    assert {:ok, %Message{} = message} =
             Message.normalize(%{
               role: :assistant,
               content: [
                 %{text: "working"},
                 %{
                   type: "tool_use",
                   id: "call_1",
                   name: "froth_echo",
                   input: %{text: "hi"},
                   extra_content: %{google: %{thought_signature: "sig_123"}}
                 }
               ]
             })

    assert message.role == :assistant

    assert message.content == [
             %{"type" => "text", "text" => "working"},
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "hi"},
               "extra_content" => %{
                 "google" => %{"thought_signature" => "sig_123"}
               }
             }
           ]

    assert Message.text_content(message) == "working"

    assert Message.tool_uses(message) == [
             %{
               "type" => "tool_use",
               "id" => "call_1",
               "name" => "froth_echo",
               "input" => %{"text" => "hi"},
               "extra_content" => %{
                 "google" => %{"thought_signature" => "sig_123"}
               }
             }
           ]
  end

  test "extracts tool results from normalized user messages" do
    message =
      Message.user([
        "before ",
        %{"type" => "text", "text" => "after"},
        %{
          "type" => "tool_result",
          "tool_use_id" => "call_1",
          "content" => "echoed: hi"
        }
      ])

    assert Message.text_content(message) == "before after"

    assert Message.tool_results(message) == [
             %{
               "type" => "tool_result",
               "tool_use_id" => "call_1",
               "content" => "echoed: hi"
             }
           ]
  end

  test "rejects unsupported roles" do
    assert :error =
             Message.normalize(%{"role" => "tool", "content" => "nope"})
  end
end
