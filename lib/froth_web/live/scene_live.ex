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

    # Copy background to static if exists
    bg_url = if File.exists?(bg_path) do
      static_bg = "/home/mbrock/froth/priv/static/assets/scene_bg.png"
      File.cp!(bg_path, static_bg)
      "/froth/assets/scene_bg.png"
    else
      nil
    end

    _spawn_points = walkmap["spawn_points"] || [%{"x" => 600, "y" => 900, "facing" => "right"}]

    characters = [
      %{id: "char_0", name: "Cloud", x: 600, y: 900, target_x: nil, target_y: nil, state: "idle", facing: "right"},
      %{id: "char_1", name: "Lara", x: 900, y: 900, target_x: nil, target_y: nil, state: "idle", facing: "left"}
    ]

    {:ok,
     socket
     |> assign(:bg_url, bg_url)
     |> assign(:walkmap, walkmap)
     |> assign(:characters, characters)
     |> assign(:selected_char, "char_0")
     |> assign(:show_walkmap, false)}
  end

  @impl true
  def handle_event("toggle-walkmap", _, socket) do
    {:noreply, assign(socket, :show_walkmap, !socket.assigns.show_walkmap)}
  end

  @impl true
  def handle_event("scene-click", %{"x" => x, "y" => y}, socket) do
    selected = socket.assigns.selected_char
    if selected do
      characters = Enum.map(socket.assigns.characters, fn c ->
        if c.id == selected do
          %{c | target_x: x, target_y: y, state: "walking"}
        else
          c
        end
      end)
      {:noreply, socket
       |> push_event("move-character", %{id: selected, x: x, y: y})
       |> assign(:characters, characters)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select-char", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_char, id)}
  end

  @impl true
  def handle_event("char-arrived", %{"id" => id}, socket) do
    characters = Enum.map(socket.assigns.characters, fn c ->
      if c.id == id, do: %{c | state: "idle", target_x: nil, target_y: nil}, else: c
    end)
    {:noreply, assign(socket, :characters, characters)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="width: 100vw; height: 100vh; overflow: hidden; background: #111; position: relative;">
      <%!-- Background layer: 2D canvas --%>
      <div id="scene-bg" phx-hook="SceneEngine"
           data-bg={@bg_url}
           data-walkmap={Jason.encode!(@walkmap)}
           data-characters={Jason.encode!(@characters)}
           data-show-walkmap={to_string(@show_walkmap)}
           style="width: 100%; height: 100%; position: absolute; top: 0; left: 0; cursor: crosshair;">
        <canvas id="game-canvas" style="display: block; width: 100%; height: 100%;"></canvas>
      </div>

      <%!-- 3D character layer: Three.js overlay --%>
      <div id="scene-3d" phx-hook="SceneEngine3D"
           data-walkmap={Jason.encode!(@walkmap)}
           data-characters={Jason.encode!(@characters)}
           data-show-walkmap={to_string(@show_walkmap)}
           style="width: 100%; height: 100%; position: absolute; top: 0; left: 0; pointer-events: none;">
      </div>

      <%!-- HUD --%>
      <div style="position: fixed; top: 10px; left: 10px; z-index: 100; display: flex; flex-direction: column; gap: 6px;">
        <button phx-click="toggle-walkmap"
          style={"padding: 6px 12px; font-family: monospace; font-size: 12px; background: #{if @show_walkmap, do: "#4a4", else: "#333"}; color: #eee; border: 1px solid #666; cursor: pointer;"}>
          walk map <%= if @show_walkmap, do: "ON", else: "OFF" %>
        </button>

        <%= for char <- @characters do %>
          <button phx-click="select-char" phx-value-id={char.id}
            style={"padding: 4px 10px; font-family: monospace; font-size: 11px; background: #{if @selected_char == char.id, do: "#448", else: "#222"}; color: #eee; border: 1px solid #{if @selected_char == char.id, do: "#88f", else: "#555"}; cursor: pointer;"}>
            <%= char.name %> (<%= char.state %>)
          </button>
        <% end %>

        <div style="margin-top: 8px; padding: 6px; background: rgba(0,0,0,0.7); font-family: monospace; font-size: 10px; color: #888; max-width: 200px;">
          Click: move selected character<br/>
          Right-drag: pan camera<br/>
          Scroll: zoom<br/>
          Characters: FF7-style polygon meshes<br/>
          Background: Flux 2 Pro painting<br/>
          Walk map: Gemini Flash extraction
        </div>
      </div>
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
