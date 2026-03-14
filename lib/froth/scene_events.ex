defmodule Froth.SceneEvents do
  @moduledoc """
  Event-sourced scene state. Every mutation is an event with a JSON payload.
  The current state is the reduction of all events in sequence order.

  Event types:
    "set_background"     — %{"url" => "..."}
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

  schema "scene_events" do
    field :scene_id, :string
    field :type, :string
    field :payload, :map
    field :author, :string
    field :seq, :integer, read_after_writes: true

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

  def apply_event(%{type: "add_walk_polygon", payload: p}, state) do
    poly = %{vertices: p["vertices"], surface: p["surface"] || "grass", elevation: p["elevation"] || 0}
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
    %{state | projection: %{
      scale: p["scale"] || 1.0,
      offset_x: p["offset_x"] || 0,
      offset_y: p["offset_y"] || 0,
      rotation: p["rotation"] || 0
    }}
  end

  def apply_event(%{type: "add_character", payload: p}, state) do
    char = %{type: p["type"] || "cloud", x: p["x"] || 500, y: p["y"] || 500}
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

  def apply_event(_, state), do: state

  @doc "Serialize state to JSON-friendly map for the client."
  def to_client(state) do
    %{
      background: state.background,
      dimensions: state.dimensions,
      projection: state.projection,
      walk_polygons: state.walk_polygons |> Enum.map(fn {id, p} -> Map.put(p, :id, id) end),
      blocked_regions: state.blocked_regions |> Enum.map(fn {id, r} -> Map.put(r, :id, id) end),
      objects: state.objects |> Enum.map(fn {id, o} -> Map.put(o, :id, id) end),
      spawns: state.spawns |> Enum.map(fn {id, s} -> Map.put(s, :id, id) end),
      characters: state.characters |> Enum.map(fn {id, c} -> Map.put(c, :id, id) end)
    }
  end
end
