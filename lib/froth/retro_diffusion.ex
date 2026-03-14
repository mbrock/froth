defmodule Froth.RetroDiffusion do
  @moduledoc """
  Retro Diffusion pixel art generation API client.

  Generates pixel art images via the RetroDiffusion API and saves results
  to disk with full JSON metadata preserved.

  ## Usage

      # Direct (blocking) call:
      {:ok, result} = Froth.RetroDiffusion.generate("ghost uncle", style: :fantasy)
      # => %{image_path: "/path/to.png", meta_path: "/path/to.json", cost: 0.22, ...}

      # Via Oban job queue (non-blocking):
      {:ok, job} = Froth.RetroDiffusion.enqueue("pizzeria interior",
        style: :dungeon_map, width: 256, height: 256,
        chat_id: -1003690254489, send: true)

  ## Styles (rd_pro)

  :default, :painterly, :fantasy, :horror, :scifi, :simple,
  :isometric, :topdown, :platformer, :dungeon_map, :spritesheet,
  :typography, :hexagonal_tiles, :fps_weapon, :inventory_items, :ui_panel

  ## Models

  :fast (rd_fast, ~1.5¢), :plus (rd_plus, ~2.5¢), :pro (rd_pro, ~22¢)
  """

  require Logger

  @api_url "https://api.retrodiffusion.ai/v1/inferences"
  @output_dir "/home/mbrock/retro-diffusion"

  @doc """
  Generate an image synchronously. Returns {:ok, result} or {:error, reason}.

  Options:
    - :style - atom, one of the rd_pro styles (default: :default)
    - :model - :fast, :plus, :pro (default: :pro)
    - :width - 96..256 (default: 128)
    - :height - 96..256 (default: 128)
    - :num_images - 1..4 (default: 1)
  """
  def generate(prompt, opts \\ []) do
    style = Keyword.get(opts, :style, :default)
    model = Keyword.get(opts, :model, :pro)
    width = Keyword.get(opts, :width, 128)
    height = Keyword.get(opts, :height, 128)
    num_images = Keyword.get(opts, :num_images, 1)

    prompt_style = build_prompt_style(model, style)

    reference_images = Keyword.get(opts, :reference_images, [])

    body_map = %{
      "prompt" => prompt,
      "prompt_style" => prompt_style,
      "width" => width,
      "height" => height,
      "num_images" => num_images,
      "include_downloadable_data" => true
    }

    body_map = if reference_images != [] do
      Map.put(body_map, "reference_images", reference_images)
    else
      body_map
    end

    body = Jason.encode!(body_map)

    case do_request(body) do
      {:ok, response} ->
        save_results(prompt, style, model, response)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Enqueue an image generation as an Oban job.

  Same options as generate/2 plus:
    - :chat_id - Telegram chat to send result to
    - :send - boolean, whether to send to chat (default: false)
    - :caption - custom caption (default: auto-generated)
  """
  def enqueue(prompt, opts \\ []) do
    args = %{
      "prompt" => prompt,
      "style" => to_string(Keyword.get(opts, :style, :default)),
      "model" => to_string(Keyword.get(opts, :model, :pro)),
      "width" => Keyword.get(opts, :width, 128),
      "height" => Keyword.get(opts, :height, 128),
      "num_images" => Keyword.get(opts, :num_images, 1),
      "chat_id" => Keyword.get(opts, :chat_id),
      "send" => Keyword.get(opts, :send, false),
      "caption" => Keyword.get(opts, :caption),
      "reference_images" => Keyword.get(opts, :reference_images, [])
    }

    %{"prompt" => prompt}
    |> Map.merge(args)
    |> Froth.RetroDiffusion.Worker.new()
    |> Oban.insert()
  end

  @doc "Check remaining credits and balance."
  def credits do
    key = api_key()

    case Req.get("https://api.retrodiffusion.ai/v1/inferences/credits",
           headers: [{"x-rd-token", key}],
           receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, e} -> {:error, e}
    end
  end

  # --- internals ---

  defp do_request(body) do
    key = api_key()

    case Req.post(@api_url,
           body: body,
           headers: [
             {"x-rd-token", key},
             {"content-type", "application/json"}
           ],
           receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("RetroDiffusion API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("RetroDiffusion request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp save_results(prompt, style, model, response) do
    File.mkdir_p!(@output_dir)
    ts = DateTime.utc_now() |> DateTime.to_unix()
    slug = prompt |> String.slice(0, 40) |> String.replace(~r/[^a-zA-Z0-9]+/, "-") |> String.trim("-")
    base = "#{ts}-#{slug}"

    images = response["base64_images"] || []

    image_paths =
      images
      |> Enum.with_index()
      |> Enum.map(fn {b64, i} ->
        suffix = if length(images) > 1, do: "-#{i}", else: ""
        path = Path.join(@output_dir, "#{base}#{suffix}.png")
        File.write!(path, Base.decode64!(b64))
        path
      end)

    # Save metadata (strip base64 to keep it readable)
    meta = Map.put(response, "base64_images", Enum.map(image_paths, &"saved:#{&1}"))
    meta = Map.merge(meta, %{
      "prompt" => prompt,
      "style" => to_string(style),
      "model" => to_string(model),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
    meta_path = Path.join(@output_dir, "#{base}.json")
    File.write!(meta_path, Jason.encode!(meta, pretty: true))

    {:ok, %{
      image_paths: image_paths,
      meta_path: meta_path,
      cost: response["balance_cost"],
      remaining: response["remaining_balance"],
      credits_used: response["credit_cost"],
      credits_remaining: response["remaining_credits"],
      model: response["model"]
    }}
  end

  defp build_prompt_style(:fast, style), do: "rd_fast__#{style}"
  defp build_prompt_style(:plus, style), do: "rd_plus__#{style}"
  defp build_prompt_style(:pro, style), do: "rd_pro__#{style}"
  defp build_prompt_style(_, style), do: "rd_pro__#{style}"

  defp api_key do
    case System.get_env("RETRO_DIFFUSION_API_KEY") do
      nil -> "rdpk-deb7341b4540c61fb8a2d65f578a1d87"
      key -> key
    end
  end
end
