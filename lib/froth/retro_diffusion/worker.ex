defmodule Froth.RetroDiffusion.Worker do
  @moduledoc """
  Oban worker for Retro Diffusion image generation.

  Runs the API call in the :retro_diffusion queue and optionally sends
  the result to a Telegram chat.
  """
  use Oban.Worker, queue: :retro_diffusion, max_attempts: 3

  require Logger

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(2, attempt - 1) * 10)
  end

  @impl true
  def perform(%Oban.Job{args: args}) do
    prompt = args["prompt"]
    style = String.to_atom(args["style"] || "default")
    model = String.to_atom(args["model"] || "pro")
    width = args["width"] || 128
    height = args["height"] || 128
    num_images = args["num_images"] || 1

    Logger.info("RetroDiffusion generating: #{inspect(prompt)} (#{model}/#{style} #{width}x#{height})")

    case Froth.RetroDiffusion.generate(prompt,
           style: style, model: model,
           width: width, height: height,
           num_images: num_images) do
      {:ok, result} ->
        Logger.info("RetroDiffusion done: cost=$#{result.cost}, remaining=$#{result.remaining}")

        if args["send"] && args["chat_id"] do
          send_to_chat(args, result)
        end

        {:ok, result}

      {:error, reason} ->
        Logger.error("RetroDiffusion failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp send_to_chat(args, result) do
    chat_id = args["chat_id"]
    caption = args["caption"] || "#{args["model"]}/#{args["style"]}: '#{args["prompt"]}' — $#{result.cost}"

    Enum.each(result.image_paths, fn path ->
      Froth.Telegram.send("charlie", %{
        "@type" => "sendMessage",
        "chat_id" => chat_id,
        "input_message_content" => %{
          "@type" => "inputMessagePhoto",
          "photo" => %{
            "@type" => "inputFileLocal",
            "path" => path
          },
          "caption" => %{
            "@type" => "formattedText",
            "text" => caption
          },
          "width" => args["width"] || 128,
          "height" => args["height"] || 128
        }
      })
    end)
  end
end
