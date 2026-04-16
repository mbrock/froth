defmodule Froth.Agent.ToolDescriptionTest do
  use ExUnit.Case, async: true

  alias Froth.Agent.ToolDescription

  test "prefers the action line for structured tool descriptions" do
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
           }) == "Inspecting the runtime registry"
  end

  test "falls back to the first goal when structured descriptions omit an action" do
    assert ToolDescription.text_from_input(%{
             "description" => %{
               "goals" => [
                 "confirm whether the process exists",
                 "identify the correct pid to interrogate"
               ]
             }
           }) == "confirm whether the process exists"
  end

  test "falls back to legacy narration when no structured description is present" do
    assert ToolDescription.text_from_input(%{"narration" => "Checking the current logs."}) ==
             "Checking the current logs."
  end
end
