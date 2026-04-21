defmodule Froth.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.Message
  alias Froth.LLM.Message, as: LLMMessage

  test "to_llm_message converts user text into normalized llm content" do
    assert %LLMMessage{
             role: :user,
             content: [%{"type" => "text", "text" => "hello"}]
           } =
             Message.user("hello")
             |> Message.to_llm_message()
  end

  test "to_llm_message preserves assistant tool blocks" do
    message =
      Message.agent([
        %{
          "type" => "tool_use",
          "id" => "call_1",
          "name" => "froth_echo",
          "input" => %{"text" => "hi"}
        }
      ])

    assert %LLMMessage{
             role: :assistant,
             content: [
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "froth_echo",
                 "input" => %{"text" => "hi"}
               }
             ]
           } = Message.to_llm_message(message)
  end
end
