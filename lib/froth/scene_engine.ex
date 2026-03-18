defmodule Froth.SceneEngine do
  @moduledoc """
  Pre-rendered RPG scene pipeline.

  Generates backgrounds with Flux/Replicate, extracts walk maps
  with Gemini, generates character sprites with RetroDiffusion,
  and serves them through a Phoenix LiveView game renderer.

  ## Pipeline

  1. Generate background: Flux 2 Pro via Replicate (2048x1376, 3:2)
  2. Extract walk map: Gemini Flash structured JSON extraction
  3. Generate characters: RetroDiffusion walking/idle animations
  4. Render: Canvas2D in browser, Phoenix channel for state

  ## Usage

      # Generate a complete scene
      {:ok, scene} = Froth.SceneEngine.generate_scene(
        "Fantasy village square at twilight",
        characters: ["wizard", "rogue", "knight"])

      # Or step by step:
      {:ok, bg} = Froth.SceneEngine.generate_background("Ancient forest clearing")
      {:ok, walkmap} = Froth.SceneEngine.extract_walkmap(bg.image_path)
      {:ok, chars} = Froth.SceneEngine.generate_characters(["wizard", "rogue"])
  """

  require Logger

  @output_dir "/home/mbrock/retro-diffusion/scenes"

  @doc "Generate a background image with Flux 2 Pro."
  def generate_background(description, opts \\ []) do
    prompt = """
    Pre-rendered RPG background painting. #{description}. \
    Painterly, photorealistic lighting, lush vegetation, rich saturated \
    fantasy colors, dramatic depth of field with foreground elements framing \
    the scene. Cinematic three-quarter overhead perspective like a CRPG camera. \
    Baldur's Gate 3 aesthetic. Not pixel art. Not isometric.
    """

    model = Keyword.get(opts, :model, "black-forest-labs/flux-2-pro")

    {:ok, pred} =
      Froth.Replicate.start(String.trim(prompt),
        model: model,
        aspect_ratio: "3:2",
        resolution: "4 MP",
        output_format: "png",
        output_quality: 100,
        safety_tolerance: 5
      )

    {:ok, done} = Froth.Replicate.await(pred.id)

    url =
      cond do
        is_list(done.output) and length(done.output) > 0 -> hd(done.output)
        is_binary(done.output) -> done.output
        true -> nil
      end

    if url do
      File.mkdir_p!(@output_dir)
      ts = DateTime.utc_now() |> DateTime.to_unix()

      slug =
        description
        |> String.slice(0, 30)
        |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
        |> String.trim("-")

      path = Path.join(@output_dir, "bg-#{ts}-#{slug}.png")

      {:ok, %{body: body}} = Req.get(url, receive_timeout: 60_000)
      File.write!(path, body)

      Logger.info("SceneEngine background: #{path} (#{byte_size(body)} bytes)")
      {:ok, %{image_path: path, size: byte_size(body), prediction_id: pred.id}}
    else
      {:error, :no_output}
    end
  end

  @doc "Extract a structured walk map from a background image using Gemini."
  def extract_walkmap(image_path, opts \\ []) do
    image_data = File.read!(image_path)
    b64 = Base.encode64(image_data)

    # Detect dimensions
    {info, 0} = System.cmd("file", [image_path])
    {width, height} = parse_dimensions(info)

    model = Keyword.get(opts, :model, "gemini-3-flash-preview")

    prompt = walkmap_prompt(width, height)

    contents = [
      %{
        "role" => "user",
        "parts" => [
          %{"text" => prompt},
          %{"inline_data" => %{"mime_type" => "image/png", "data" => b64}}
        ]
      }
    ]

    case Froth.Analyzer.API.gemini(model, contents, max_output_tokens: 16384) do
      {:ok, text} ->
        cleaned =
          text
          |> String.replace(~r/^```json\n?/, "")
          |> String.replace(~r/\n?```$/, "")
          |> String.trim()

        meta_path = String.replace(image_path, ~r/\.png$/, "-walkmap.json")
        File.write!(meta_path, cleaned)

        case Jason.decode(cleaned) do
          {:ok, walkmap} ->
            Logger.info("SceneEngine walkmap: #{map_size(walkmap)} keys, saved to #{meta_path}")
            {:ok, %{walkmap: walkmap, meta_path: meta_path}}

          {:error, _} ->
            {:error, :json_parse_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Generate character sprites via RetroDiffusion Oban jobs."
  def generate_characters(character_descriptions) when is_list(character_descriptions) do
    jobs =
      for {prompt, name} <- character_descriptions do
        {:ok, job} =
          Froth.RetroDiffusion.enqueue(
            prompt,
            style: :default,
            model: :pro,
            width: 96,
            height: 96
          )

        {name, job.id}
      end

    {:ok, jobs}
  end

  # --- private ---

  defp walkmap_prompt(width, height) do
    """
    You are analyzing a high-resolution RPG background image (#{width}x#{height} pixels) to extract structured game engine data.
    Return ONLY valid JSON with no markdown fencing. The JSON must have these fields:

    {
      "scene_description": "brief description",
      "dimensions": {"width": #{width}, "height": #{height}},
      "walk_polygons": [
        {"id": "walkable_1", "vertices": [[x1,y1], [x2,y2], ...], "surface": "cobblestone|grass|wood|water|dirt|stone", "elevation": 0}
      ],
      "blocked_regions": [
        {"id": "blocked_1", "vertices": [[x1,y1], ...], "type": "wall|furniture|tree|water|building|rock"}
      ],
      "foreground_layers": [
        {"id": "fg_1", "bounding_box": {"x": 0, "y": 0, "w": 50, "h": 80}, "description": "...", "depth_order": 1}
      ],
      "spawn_points": [
        {"id": "entrance_1", "x": 128, "y": 240, "facing": "up|down|left|right"}
      ],
      "interactive_objects": [
        {"id": "obj_1", "x": 100, "y": 100, "type": "chest|door|npc|sign|shrine|campfire|container", "description": "..."}
      ],
      "lighting": {
        "ambient_color": "#rrggbb",
        "time_of_day": "golden_hour|dawn|dusk|night|noon",
        "light_sources": [{"x": 100, "y": 50, "color": "#ffaa44", "radius": 80, "type": "lantern|fire|magical|sunbeam"}]
      }
    }

    Be thorough. Trace ALL walkable paths with precise pixel coordinates in the full #{width}x#{height} space.
    """
  end

  defp parse_dimensions(file_info) do
    case Regex.run(~r/(\d+)\s*x\s*(\d+)/, file_info) do
      [_, w, h] -> {String.to_integer(w), String.to_integer(h)}
      _ -> {2048, 1376}
    end
  end
end
