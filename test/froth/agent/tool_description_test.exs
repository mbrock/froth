defmodule Froth.Agent.ToolDescriptionTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.ToolDescription

  test "renders structured tool descriptions into observer prose" do
    assert ToolDescription.text_from_input(%{
             "description" => %{
               "action" => "Inspecting the runtime registry",
               "goals" => [
                 "confirm whether the process exists",
                 "identify the correct pid to interrogate",
                 "avoid inventing state from memory",
                 "this should be ignored"
               ],
               "assumptions" => ["the registry is available", "the name is spelled correctly"]
             }
           }) ==
             "Inspecting the runtime registry\n" <>
               "Goal stack: confirm whether the process exists -> identify the correct pid to interrogate -> avoid inventing state from memory\n" <>
               "Assumptions: the registry is available; the name is spelled correctly"
  end

  test "falls back to legacy narration when no structured description is present" do
    assert ToolDescription.text_from_input(%{"narration" => "Checking the current logs."}) ==
             "Checking the current logs."
  end
end
