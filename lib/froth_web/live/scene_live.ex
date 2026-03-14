defmodule FrothWeb.SceneLive do
  use FrothWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Use the existing Flux 2 Pro background and walkmap
    bg_path = "/tmp/bg3_2841.png"
    walkmap_path = "/tmp/walkmap_bg3_flash.json"

    # Load walkmap if exists
    walkmap = if File.exists?(walkmap_path) do
      case File.read!(walkmap_path) |> Jason.decode() do
        {:ok, data} -> data
        _ -> default_walkmap()
      end
    else
      default_walkmap()
    end

    # Find available character sprites from retro-diffusion output
    sprites = find_character_sprites()

    # Initial game state — characters placed at spawn points
    spawn_points = walkmap["spawn_points"] || [%{"x" => 500, "y" => 800, "facing" => "right"}]
    first_spawn = hd(spawn_points)

    characters = sprites
    |> Enum.with_index()
    |> Enum.map(fn {{name, sprite_path}, i} ->
      sp = Enum.at(spawn_points, rem(i, length(spawn_points)), first_spawn)
      %{
        id: "char_#{i}",
        name: name,
        sprite: sprite_url(sprite_path),
        x: sp["x"] + i * 60,
        y: sp["y"] + i * 40,
        target_x: nil,
        target_y: nil,
        state: "idle",
        facing: "right",
        speed: 2
      }
    end)

    # Serve background image as a data URI or static path
    bg_url = if File.exists?(bg_path) do
      # Copy to static assets for serving
      static_bg = "/home/mbrock/froth/priv/static/assets/scene_bg.png"
      File.cp!(bg_path, static_bg)
      "/froth/assets/scene_bg.png"
    else
      nil
    end

    # Copy sprites to static too
    for {_name, sprite_path} <- sprites do
      basename = Path.basename(sprite_path)
      static_path = "/home/mbrock/froth/priv/static/assets/sprites/#{basename}"
      File.mkdir_p!(Path.dirname(static_path))
      File.cp!(sprite_path, static_path)
    end

    {:ok,
     socket
     |> assign(:bg_url, bg_url)
     |> assign(:walkmap, walkmap)
     |> assign(:characters, characters)
     |> assign(:selected_char, nil)
     |> assign(:show_walkmap, false)
     |> assign(:sprites, sprites)}
  end

  @impl true
  def handle_event("toggle-walkmap", _, socket) do
    {:noreply, assign(socket, :show_walkmap, !socket.assigns.show_walkmap)}
  end

  @impl true
  def handle_event("scene-click", %{"x" => x, "y" => y}, socket) do
    # Move selected character to click position
    selected = socket.assigns.selected_char
    if selected do
      characters = Enum.map(socket.assigns.characters, fn c ->
        if c.id == selected do
          %{c | target_x: x, target_y: y, state: "walking"}
        else
          c
        end
      end)
      {:noreply, push_event(socket, "move-character", %{id: selected, x: x, y: y})
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
      if c.id == id do
        %{c | state: "idle", target_x: nil, target_y: nil}
      else
        c
      end
    end)
    {:noreply, assign(socket, :characters, characters)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="scene-engine" phx-hook="SceneEngine"
         data-bg={@bg_url}
         data-walkmap={Jason.encode!(@walkmap)}
         data-characters={Jason.encode!(@characters)}
         data-show-walkmap={to_string(@show_walkmap)}
         style="width: 100vw; height: 100vh; overflow: hidden; background: #111; position: relative; cursor: crosshair;">

      <canvas id="game-canvas" style="display: block; width: 100%; height: 100%; object-fit: contain;"></canvas>

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
      </div>

      <div style="position: fixed; bottom: 10px; left: 10px; z-index: 100; font-family: monospace; font-size: 11px; color: #888;">
        Click to move selected character. Walk polygons from Gemini Flash. Background by Flux 2 Pro. Sprites by RetroDiffusion.
      </div>
    </div>
    """
  end

  defp sprite_url(path) do
    basename = Path.basename(path)
    "/froth/assets/sprites/#{basename}"
  end

  defp find_character_sprites do
    dir = "/home/mbrock/retro-diffusion"
    if File.dir?(dir) do
      File.ls!(dir)
      |> Enum.filter(&String.ends_with?(&1, ".png"))
      |> Enum.sort()
      |> Enum.take(8)
      |> Enum.map(fn f ->
        name = f
        |> String.replace(~r/^\d+-/, "")
        |> String.replace(".png", "")
        |> String.replace("-", " ")
        |> String.slice(0, 20)
        {name, Path.join(dir, f)}
      end)
    else
      []
    end
  end

  defp default_walkmap do
    %{
      "dimensions" => %{"width" => 2048, "height" => 1376},
      "walk_polygons" => [
        %{"id" => "main_path", "vertices" => [[200,1200],[1800,1200],[1800,900],[200,900]], "surface" => "grass", "elevation" => 0}
      ],
      "blocked_regions" => [],
      "foreground_layers" => [],
      "spawn_points" => [%{"id" => "start", "x" => 400, "y" => 1000, "facing" => "right"}],
      "interactive_objects" => [],
      "lighting" => %{"ambient_color" => "#ffd700", "time_of_day" => "golden_hour", "light_sources" => []}
    }
  end
end
