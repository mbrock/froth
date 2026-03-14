defmodule FrothWeb.SceneLive do
  use FrothWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    bg_path = "/tmp/bg3_2841.png"
    walkmap_path = "/tmp/walkmap_bg3_flash.json"

    walkmap = if File.exists?(walkmap_path) do
      case File.read!(walkmap_path) |> Jason.decode() do
        {:ok, data} -> data
        _ -> default_walkmap()
      end
    else
      default_walkmap()
    end

    bg_url = if File.exists?(bg_path) do
      static_bg = "/home/mbrock/froth/priv/static/assets/scene_bg.png"
      File.cp!(bg_path, static_bg)
      "/froth/assets/scene_bg.png"
    else
      nil
    end

    characters = [
      %{id: "cloud", name: "Cloud", x: 600, y: 900, state: "wandering", facing: "right"},
      %{id: "lara", name: "Lara", x: 900, y: 1000, state: "wandering", facing: "left"}
    ]

    {:ok,
     socket
     |> assign(:bg_url, bg_url)
     |> assign(:walkmap, walkmap)
     |> assign(:characters, characters)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="scene-view" phx-hook="SceneView"
         data-bg={@bg_url}
         data-walkmap={Jason.encode!(@walkmap)}
         data-characters={Jason.encode!(@characters)}
         style="width: 100vw; height: 100vh; overflow: hidden; background: #111; position: relative;">
      <canvas id="game-canvas" style="display: block; width: 100%; height: 100%;"></canvas>
    </div>
    """
  end

  defp default_walkmap do
    %{
      "dimensions" => %{"width" => 2048, "height" => 1376},
      "walk_polygons" => [
        %{"id" => "main", "vertices" => [[200,900],[1800,900],[1800,1200],[200,1200]], "surface" => "grass", "elevation" => 0}
      ],
      "blocked_regions" => [],
      "foreground_layers" => [],
      "spawn_points" => [%{"id" => "start", "x" => 600, "y" => 900, "facing" => "right"}],
      "interactive_objects" => [],
      "lighting" => %{"ambient_color" => "#ffd700", "time_of_day" => "golden_hour", "light_sources" => []}
    }
  end
end
