defmodule Froth.SceneEventsTest do
  use ExUnit.Case, async: true

  alias Froth.SceneEvents

  test "legacy plane events are exposed as vertex-scaled regions" do
    state =
      SceneEvents.initial_state()
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "add_plane",
            payload: %{
              "id" => "plane_1",
              "corners" => [[100, 120], [240, 120], [320, 340], [40, 340]],
              "surface" => "cobblestone",
              "reference_scale" => 84
            }
          },
          state
        )
      end)

    client = SceneEvents.to_client(state)
    [region] = client.regions

    assert region.id == "plane_1"
    assert region.surface == "cobblestone"
    assert region.polygon == [[100, 120], [240, 120], [320, 340], [40, 340]]
    assert region.vertex_heights == [42, 43, 84, 83]
  end

  test "legacy depth-based regions are normalized into vertex heights" do
    state =
      SceneEvents.initial_state()
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "add_region",
            payload: %{
              "id" => "shared_1",
              "label" => "Bridge deck",
              "surface" => "wood",
              "polygon" => [[10, 20], [110, 18], [120, 140], [0, 145]],
              "depth" => %{
                "far" => %{"x" => 45, "y" => 28, "height" => 28},
                "near" => %{"x" => 64, "y" => 136, "height" => 96}
              }
            }
          },
          state
        )
      end)

    client = SceneEvents.to_client(state)
    [region] = client.regions

    assert region.id == "shared_1"
    assert region.label == "Bridge deck"
    assert region.surface == "wood"
    assert region.vertex_heights == [28, 29, 96, 95]
  end

  test "updating a legacy plane creates an explicit region override" do
    state =
      SceneEvents.initial_state()
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "add_plane",
            payload: %{
              "id" => "legacy_plane",
              "corners" => [[20, 30], [140, 30], [180, 180], [0, 180]],
              "reference_scale" => 78,
              "surface" => "grass"
            }
          },
          state
        )
      end)
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "update_region",
            payload: %{
              "id" => "legacy_plane",
              "label" => "Front lawn",
              "surface" => "stone"
            }
          },
          state
        )
      end)

    [region] = SceneEvents.to_client(state).regions

    assert region.id == "legacy_plane"
    assert region.label == "Front lawn"
    assert region.surface == "stone"
    assert region.vertex_heights == [52, 53, 78, 77]
  end

  test "region updates allow zero values and preserve large vertex heights" do
    state =
      SceneEvents.initial_state()
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "add_region",
            payload: %{
              "id" => "region_1",
              "label" => "Courtyard",
              "surface" => "stone",
              "elevation" => 3,
              "polygon" => [[10, 10], [40, 10], [40, 40], [10, 40]],
              "vertex_heights" => [24, 32, 72, 68]
            }
          },
          state
        )
      end)
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "update_region",
            payload: %{
              "id" => "region_1",
              "label" => "Lower court",
              "elevation" => 0,
              "vertex_heights" => [20, 26, 488, 482]
            }
          },
          state
        )
      end)

    [region] = SceneEvents.to_client(state).regions

    assert region.label == "Lower court"
    assert region.elevation == 0
    assert region.vertex_heights == [20, 26, 488, 482]
  end

  test "character events preserve explicit zero coordinates" do
    state =
      SceneEvents.initial_state()
      |> then(fn state ->
        SceneEvents.apply_event(
          %{
            type: "add_character",
            payload: %{"id" => "cloud_1", "type" => "cloud", "x" => 0, "y" => 0}
          },
          state
        )
      end)

    [character] = SceneEvents.to_client(state).characters

    assert character.x == 0
    assert character.y == 0
  end
end
