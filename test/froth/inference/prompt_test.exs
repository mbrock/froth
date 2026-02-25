defmodule Froth.Inference.PromptTest do
  use ExUnit.Case, async: true

  alias Froth.Inference.Prompt

  describe "initial_user_content/3" do
    test "uses one cache breakpoint on the final context block" do
      context_blocks = [
        "<summary date=\"2026-02-15\">Summary text</summary>",
        "\n\n<recent>\n[2026-02-16 00:00 UTC] msg:100 sender:42: hello"
      ]

      eval_hint = "\n<elixir_eval_lookup>\ninference_session_id=123\n</elixir_eval_lookup>"

      new_messages_section = """
      <message id=\"10\" from=\"42\">
      hello
      </message>
      """

      content = Prompt.initial_user_content(context_blocks, eval_hint, new_messages_section)
      assert is_list(content)
      assert length(content) == 3

      assert Enum.at(content, 0) == %{"type" => "text", "text" => Enum.at(context_blocks, 0)}

      assert Enum.at(content, 1) == %{
               "type" => "text",
               "text" => Enum.at(context_blocks, 1),
               "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
             }

      assert %{"type" => "text", "text" => suffix} = Enum.at(content, 2)
      refute Map.has_key?(Enum.at(content, 2), "cache_control")

      cache_breakpoints =
        Enum.count(content, fn block ->
          is_map(block) and Map.has_key?(block, "cache_control")
        end)

      assert cache_breakpoints == 1
      assert suffix =~ "<new_messages>"
      assert suffix =~ "Respond to these messages. Use the send_message tool."
    end

    test "caches the context prefix when context is present" do
      context = "<summary date=\"2026-02-15\">Summary text</summary>"
      eval_hint = "\n<elixir_eval_lookup>\ninference_session_id=123\n</elixir_eval_lookup>"

      new_messages_section = """
      <message id=\"10\" from=\"42\">
      hello
      </message>
      """

      content = Prompt.initial_user_content(context, eval_hint, new_messages_section)
      assert is_list(content)

      assert [
               %{
                 "type" => "text",
                 "text" => ^context,
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               },
               %{"type" => "text", "text" => suffix}
             ] = content

      assert suffix =~ "<new_messages>"
      assert suffix =~ "Respond to these messages. Use the send_message tool."

      rebuilt_prompt = Enum.map_join(content, "", & &1["text"])
      assert rebuilt_prompt == Prompt.full_user_prompt(context, eval_hint, new_messages_section)
    end

    test "returns the original prompt string when context block list is empty" do
      new_messages_section = """
      <message id=\"11\" from=\"77\">
      hi
      </message>
      """

      content = Prompt.initial_user_content([], "", new_messages_section)

      assert is_binary(content)
      assert content == Prompt.full_user_prompt("", "", new_messages_section)
      assert content =~ "<new_messages>"
    end

    test "returns the original prompt string when context is blank" do
      new_messages_section = """
      <message id=\"11\" from=\"77\">
      hi
      </message>
      """

      content = Prompt.initial_user_content("", "", new_messages_section)

      assert is_binary(content)
      assert content == Prompt.full_user_prompt("", "", new_messages_section)
      assert content =~ "<new_messages>"
    end
  end
end
