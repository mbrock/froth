defmodule Froth.SceneEvents do
  @moduledoc """
  Event-sourced scene state. Every mutation is an event with a JSON payload.
  The current state is the reduction of all events in sequence order.

  Event types:
    "set_background"     — %{"url" => "..."}
    "add_region"         — %{
      "id" => "...",
      "polygon" => [[x,y],...],
      "label" => "...",
      "surface" => "...",
      "elevation" => 0,
      "vertex_heights" => [N, ...]
    }
    "update_region"      — partial update for the same shape
    "remove_region"      — %{"id" => "..."}
    "add_walk_polygon"   — %{"id" => "...", "vertices" => [[x,y],...], "surface" => "..."}
    "update_walk_polygon" — %{"id" => "...", "vertices" => [[x,y],...]}
    "remove_walk_polygon" — %{"id" => "..."}
    "add_blocked_region"  — %{"id" => "...", "vertices" => [[x,y],...], "type" => "..."}
    "remove_blocked_region" — %{"id" => "..."}
    "add_object"         — %{"id" => "...", "x" => N, "y" => N, "type" => "...", "label" => "..."}
    "remove_object"      — %{"id" => "..."}
    "add_spawn"          — %{"id" => "...", "x" => N, "y" => N, "facing" => "..."}
    "remove_spawn"       — %{"id" => "..."}
    "set_projection"     — %{"scale" => N, "offset_x" => N, "offset_y" => N, "rotation" => N}
    "move_character"     — %{"id" => "...", "x" => N, "y" => N}
    "add_character"      — %{"id" => "...", "type" => "cloud|lara|custom", "x" => N, "y" => N}
  """

  use Ecto.Schema
  import Ecto.Query

  @min_vertex_height 16
  @max_vertex_height 720

  schema "scene_events" do
    field(:scene_id, :string)
    field(:type, :string)
    field(:payload, :map)
    field(:author, :string)
    field(:seq, :integer, read_after_writes: true)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Append an event to a scene. Returns {:ok, event}."
  def append(scene_id, type, payload, opts \\ []) do
    author = Keyword.get(opts, :author, "system")

    %__MODULE__{}
    |> Ecto.Changeset.change(%{
      scene_id: scene_id,
      type: type,
      payload: payload,
      author: author
    })
    |> Froth.Repo.insert()
  end

  @doc "Get all events for a scene in sequence order."
  def events(scene_id) do
    from(e in __MODULE__,
      where: e.scene_id == ^scene_id,
      order_by: [asc: e.seq]
    )
    |> Froth.Repo.all()
  end

  @doc "Get events after a given sequence number (for catching up)."
  def events_after(scene_id, after_seq) do
    from(e in __MODULE__,
      where: e.scene_id == ^scene_id and e.seq > ^after_seq,
      order_by: [asc: e.seq]
    )
    |> Froth.Repo.all()
  end

  @doc "Materialize current scene state by replaying all events."
  def materialize(scene_id) do
    events(scene_id)
    |> Enum.reduce(initial_state(), &apply_event/2)
  end

  def initial_state do
    %{
      background: nil,
      walk_polygons: %{},
      planes: %{},
      regions: %{},
      blocked_regions: %{},
      objects: %{},
      spawns: %{},
      characters: %{},
      projection: %{scale: 1.0, offset_x: 0, offset_y: 0, rotation: 0},
      dimensions: %{width: 2048, height: 1376}
    }
  end

  def apply_event(%{type: "set_background", payload: p}, state) do
    %{state | background: p["url"]}
  end

  def apply_event(%{type: "add_region", payload: p}, state) do
    put_in(state, [:regions, p["id"]], normalize_region_payload(p))
  end

  def apply_event(%{type: "update_region", payload: p}, state) do
    region =
      case Map.get(state.regions, p["id"]) do
        nil ->
          case Map.get(state.planes, p["id"]) do
            nil -> nil
            plane -> legacy_plane_to_region(p["id"], plane)
          end

        existing ->
          existing
      end

    case region do
      nil -> state
      existing -> put_in(state, [:regions, p["id"]], merge_region(existing, p))
    end
  end

  def apply_event(%{type: "remove_region", payload: p}, state) do
    update_in(state, [:regions], &Map.delete(&1, p["id"]))
  end

  def apply_event(%{type: "add_walk_polygon", payload: p}, state) do
    poly = %{
      vertices: p["vertices"],
      surface: p["surface"] || "grass",
      elevation: p["elevation"] || 0
    }

    put_in(state, [:walk_polygons, p["id"]], poly)
  end

  def apply_event(%{type: "update_walk_polygon", payload: p}, state) do
    update_in(state, [:walk_polygons, p["id"]], fn existing ->
      if existing, do: Map.merge(existing, %{vertices: p["vertices"]}), else: nil
    end)
  end

  def apply_event(%{type: "remove_walk_polygon", payload: p}, state) do
    update_in(state, [:walk_polygons], &Map.delete(&1, p["id"]))
  end

  def apply_event(%{type: "add_blocked_region", payload: p}, state) do
    region = %{vertices: p["vertices"], type: p["type"] || "wall"}
    put_in(state, [:blocked_regions, p["id"]], region)
  end

  def apply_event(%{type: "remove_blocked_region", payload: p}, state) do
    update_in(state, [:blocked_regions], &Map.delete(&1, p["id"]))
  end

  def apply_event(%{type: "add_object", payload: p}, state) do
    obj = %{x: p["x"], y: p["y"], type: p["type"], label: p["label"] || ""}
    put_in(state, [:objects, p["id"]], obj)
  end

  def apply_event(%{type: "remove_object", payload: p}, state) do
    update_in(state, [:objects], &Map.delete(&1, p["id"]))
  end

  def apply_event(%{type: "add_spawn", payload: p}, state) do
    spawn = %{x: p["x"], y: p["y"], facing: p["facing"] || "right"}
    put_in(state, [:spawns, p["id"]], spawn)
  end

  def apply_event(%{type: "remove_spawn", payload: p}, state) do
    update_in(state, [:spawns], &Map.delete(&1, p["id"]))
  end

  def apply_event(%{type: "set_projection", payload: p}, state) do
    %{
      state
      | projection: %{
          scale: p["scale"] || 1.0,
          offset_x: p["offset_x"] || 0,
          offset_y: p["offset_y"] || 0,
          rotation: p["rotation"] || 0
        }
    }
  end

  def apply_event(%{type: "add_character", payload: p}, state) do
    char = %{
      type: p["type"] || "cloud",
      x: if(Map.has_key?(p, "x"), do: p["x"], else: 500),
      y: if(Map.has_key?(p, "y"), do: p["y"], else: 500)
    }

    put_in(state, [:characters, p["id"]], char)
  end

  def apply_event(%{type: "move_character", payload: p}, state) do
    update_in(state, [:characters, p["id"]], fn existing ->
      if existing, do: %{existing | x: p["x"], y: p["y"]}, else: nil
    end)
  end

  def apply_event(%{type: "set_dimensions", payload: p}, state) do
    %{state | dimensions: %{width: p["width"], height: p["height"]}}
  end

  def apply_event(%{type: "add_plane", payload: p}, state) do
    plane = normalize_plane_payload(p)
    put_in(state, [:planes, p["id"]], plane)
  end

  def apply_event(%{type: "update_plane", payload: p}, state) do
    update_in(state, [:planes, p["id"]], fn existing ->
      if existing do
        merge_plane(existing, p)
      else
        nil
      end
    end)
  end

  def apply_event(%{type: "remove_plane", payload: p}, state) do
    update_in(state, [:planes], &Map.delete(&1, p["id"]))
  end

  def apply_event(_, state), do: state

  @doc "Serialize state to JSON-friendly map for the client."
  def to_client(state) do
    regions = merged_regions(state)

    %{
      background: state.background,
      dimensions: state.dimensions,
      projection: state.projection,
      walk_polygons: serialize(state.walk_polygons),
      planes: serialize(state.planes),
      regions: serialize(regions),
      blocked_regions: serialize(state.blocked_regions),
      objects: serialize(state.objects),
      spawns: serialize(state.spawns),
      characters: serialize(state.characters)
    }
  end

  defp serialize(collection) do
    Enum.map(collection, fn {id, value} -> Map.put(value, :id, id) end)
  end

  defp normalize_plane_payload(payload) do
    %{
      corners: payload["corners"] || [],
      surface: payload["surface"] || "grass",
      elevation: payload["elevation"] || 0,
      reference_scale: payload["reference_scale"] || 60,
      grid_spacing: payload["grid_spacing"] || 2.5
    }
  end

  defp merge_plane(plane, payload) do
    plane
    |> maybe_put(:corners, payload, "corners")
    |> maybe_put(:surface, payload, "surface")
    |> maybe_put(:elevation, payload, "elevation")
    |> maybe_put(:reference_scale, payload, "reference_scale")
    |> maybe_put(:grid_spacing, payload, "grid_spacing")
  end

  defp normalize_region_payload(payload) do
    polygon = payload["polygon"] || payload["vertices"] || []

    %{
      polygon: polygon,
      label: payload["label"] || default_region_label(payload["id"]),
      surface: payload["surface"] || "stone",
      elevation: payload["elevation"] || 0,
      vertex_heights:
        normalize_vertex_heights(payload["vertex_heights"], polygon, payload["depth"])
    }
  end

  defp merge_region(region, payload) do
    polygon =
      if Map.has_key?(payload, "polygon") do
        payload["polygon"] || []
      else
        region.polygon
      end

    region =
      region
      |> maybe_put(:polygon, payload, "polygon")
      |> maybe_put(:label, payload, "label")
      |> maybe_put(:surface, payload, "surface")
      |> maybe_put(:elevation, payload, "elevation")

    vertex_heights =
      cond do
        Map.has_key?(payload, "vertex_heights") ->
          normalize_vertex_heights(payload["vertex_heights"], polygon, payload["depth"])

        Map.has_key?(payload, "depth") ->
          normalize_vertex_heights(nil, polygon, payload["depth"])

        true ->
          normalize_vertex_heights(region.vertex_heights, polygon, nil)
      end

    %{region | vertex_heights: vertex_heights}
  end

  defp maybe_put(struct, field, payload, key) do
    if Map.has_key?(payload, key) do
      Map.put(struct, field, payload[key])
    else
      struct
    end
  end

  defp normalize_vertex_heights(_vertex_heights, [], _depth), do: []

  defp normalize_vertex_heights(vertex_heights, polygon, depth) do
    heights =
      cond do
        is_list(vertex_heights) and length(vertex_heights) == length(polygon) ->
          vertex_heights

        valid_depth?(depth) ->
          heights_from_depth(polygon, depth)

        is_list(vertex_heights) and vertex_heights != [] ->
          resize_vertex_heights(vertex_heights, length(polygon))

        true ->
          default_vertex_heights(polygon)
      end

    Enum.map(heights, &clamp_height/1)
  end

  defp valid_depth?(%{"far" => %{"height" => _}, "near" => %{"height" => _}}), do: true
  defp valid_depth?(_), do: false

  defp heights_from_depth(polygon, %{"far" => far, "near" => near}) do
    far_point = {far["x"] || 0, far["y"] || 0}
    near_point = {near["x"] || 0, near["y"] || 0}
    far_height = far["height"] || 36
    near_height = near["height"] || 92

    Enum.map(polygon, fn [x, y] ->
      t = segment_position({x, y}, far_point, near_point)
      far_height + (near_height - far_height) * t
    end)
  end

  defp default_vertex_heights(polygon) do
    ys = Enum.map(polygon, &Enum.at(&1, 1))
    min_y = Enum.min(ys, fn -> 0 end)
    max_y = Enum.max(ys, fn -> 0 end)

    Enum.map(polygon, fn [_x, y] ->
      t =
        if max_y == min_y do
          0.5
        else
          (y - min_y) / (max_y - min_y)
        end

      34 + 58 * t
    end)
  end

  defp resize_vertex_heights(vertex_heights, count) do
    existing =
      vertex_heights
      |> Enum.map(&coerce_number/1)
      |> Enum.filter(&is_number/1)

    avg =
      case existing do
        [] -> 72
        values -> Enum.sum(values) / length(values)
      end

    existing
    |> Enum.take(count)
    |> then(fn values ->
      values ++ List.duplicate(avg, max(count - length(values), 0))
    end)
  end

  defp clamp_height(value) do
    value
    |> coerce_number()
    |> case do
      nil -> 72
      number -> min(@max_vertex_height, max(@min_vertex_height, round(number)))
    end
  end

  defp coerce_number(value) when is_number(value), do: value

  defp coerce_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp coerce_number(_value), do: nil

  defp segment_position({px, py}, {ax, ay}, {bx, by}) do
    dx = bx - ax
    dy = by - ay
    denom = dx * dx + dy * dy

    cond do
      denom <= 0 -> 0.5
      true -> (((px - ax) * dx + (py - ay) * dy) / denom) |> max(0.0) |> min(1.0)
    end
  end

  defp default_depth_points([]), do: {{0, 0}, {0, 0}}

  defp default_depth_points(polygon) do
    sorted = Enum.sort_by(polygon, fn [_x, y] -> y end)
    far = List.first(sorted) || [0, 0]
    near = List.last(sorted) || far
    {{Enum.at(far, 0), Enum.at(far, 1)}, {Enum.at(near, 0), Enum.at(near, 1)}}
  end

  defp distance([x1, y1], [x2, y2]) do
    :math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2))
  end

  defp merged_regions(state) do
    legacy_regions =
      state.planes
      |> Enum.reject(fn {id, _plane} -> Map.has_key?(state.regions, id) end)
      |> Enum.into(%{}, fn {id, plane} -> {id, legacy_plane_to_region(id, plane)} end)

    Map.merge(legacy_regions, state.regions)
  end

  defp legacy_plane_to_region(id, plane) do
    corners = plane.corners || []

    {far_point, near_point, far_height, near_height} =
      plane_depth(corners, plane.reference_scale || 60)

    %{
      polygon: corners,
      label: default_region_label(id),
      surface: plane.surface || "grass",
      elevation: plane.elevation || 0,
      vertex_heights:
        normalize_vertex_heights(
          nil,
          corners,
          %{
            "far" => %{
              "x" => elem(far_point, 0),
              "y" => elem(far_point, 1),
              "height" => far_height
            },
            "near" => %{
              "x" => elem(near_point, 0),
              "y" => elem(near_point, 1),
              "height" => near_height
            }
          }
        )
    }
  end

  defp plane_depth([tl, tr, br, bl], near_height) do
    far_point = midpoint(tl, tr)
    near_point = midpoint(bl, br)
    top_width = distance(tl, tr)
    bottom_width = distance(bl, br)

    ratio =
      cond do
        bottom_width <= 0 -> 0.45
        true -> max(0.2, min(0.95, top_width / bottom_width))
      end

    {far_point, near_point, max(18, round(near_height * ratio)), near_height}
  end

  defp plane_depth(corners, near_height) do
    {far_point, near_point} = default_depth_points(corners)
    {far_point, near_point, max(18, round(near_height * 0.45)), near_height}
  end

  defp midpoint([x1, y1], [x2, y2]) do
    {round((x1 + x2) / 2), round((y1 + y2) / 2)}
  end

  defp default_region_label(nil), do: "Region"

  defp default_region_label(id) do
    id
    |> to_string()
    |> String.replace(~r/[_-]+/, " ")
    |> String.trim()
    |> case do
      "" -> "Region"
      text -> String.capitalize(text)
    end
  end
end
