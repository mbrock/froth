defmodule Froth.Replicate.Storyboard do
  @moduledoc """
  Utilities for generating storyboard media from a `scenes.json` manifest.
  """

  alias Froth.Replicate

  @default_concurrency 8
  @default_video_concurrency 4
  @default_timeout 300_000
  @default_video_timeout 600_000
  @download_timeout 120_000
  @frame_width 1080
  @frame_height 1920
  @static_base_url "https://less.rest/froth"

  @doc """
  Reads a storyboard manifest, starts image predictions in parallel, waits for each
  prediction to complete, and downloads the resulting image to the manifest directory.

  Returns `{:ok, results}` where each result includes the scene id, prediction id,
  output path, and final status.
  """
  def generate_images(manifest_path, opts \\ [])
      when is_binary(manifest_path) and is_list(opts) do
    manifest_path = Path.expand(manifest_path)
    manifest_dir = Path.dirname(manifest_path)
    manifest = read_manifest(manifest_path)
    concurrency = positive_integer(Keyword.get(opts, :concurrency), @default_concurrency)
    timeout = positive_integer(Keyword.get(opts, :timeout), @default_timeout)
    scenes = manifest_scenes(manifest, opts, "image_prompt")

    IO.puts("Generating #{length(scenes)} storyboard image(s) from #{manifest_path}")

    results =
      scenes
      |> Task.async_stream(
        fn scene ->
          generate_scene_image(scene, manifest, manifest_dir, timeout)
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce([], fn
        {:ok, result}, acc ->
          [result | acc]

        {:exit, reason}, acc ->
          IO.puts("Storyboard task exited: #{inspect(reason)}")
          acc
      end)
      |> Enum.reverse()

    {:ok, results}
  end

  @doc """
  Reads a storyboard manifest, prepares public reference assets, starts video
  predictions in parallel, waits for each prediction to complete, and downloads
  the resulting clip to the manifest directory.

  Returns `{:ok, results}` where each result includes the scene id, prediction id,
  output path, and final status.
  """
  def generate_videos(manifest_path, opts \\ [])
      when is_binary(manifest_path) and is_list(opts) do
    manifest_path = Path.expand(manifest_path)
    manifest_dir = Path.dirname(manifest_path)
    manifest = read_manifest(manifest_path)
    concurrency = positive_integer(Keyword.get(opts, :concurrency), @default_video_concurrency)
    timeout = positive_integer(Keyword.get(opts, :timeout), @default_video_timeout)
    scenes = manifest_scenes(manifest, opts, "video_prompt")

    IO.puts("Generating #{length(scenes)} storyboard video(s) from #{manifest_path}")

    results =
      scenes
      |> Task.async_stream(
        fn scene ->
          generate_scene_video(scene, manifest, manifest_dir, timeout)
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce([], fn
        {:ok, result}, acc ->
          [result | acc]

        {:exit, reason}, acc ->
          IO.puts("Storyboard video task exited: #{inspect(reason)}")
          acc
      end)
      |> Enum.reverse()

    {:ok, results}
  end

  @doc """
  Resizes generated storyboard images to 1080x1920 and writes them to a `frames/`
  subdirectory next to the manifest.
  """
  def resize_frames(manifest_path, opts \\ [])
      when is_binary(manifest_path) and is_list(opts) do
    manifest_path = Path.expand(manifest_path)
    manifest_dir = Path.dirname(manifest_path)
    frames_dir = Path.join(manifest_dir, "frames")
    manifest = read_manifest(manifest_path)
    scenes = manifest_scenes(manifest, opts, "image_prompt")

    File.mkdir_p!(frames_dir)

    IO.puts("Resizing #{length(scenes)} storyboard frame(s) into #{frames_dir}")

    results =
      Enum.map(scenes, fn scene ->
        resize_scene_frame(scene, manifest_dir, frames_dir)
      end)

    {:ok, results}
  end

  defp generate_scene_image(scene, manifest, manifest_dir, timeout) do
    scene_id = scene_id(scene)
    output_path = Path.join(manifest_dir, "#{scene_id}.png")
    prompt = full_prompt(manifest, scene)
    model = Map.fetch!(manifest, "image_model")
    aspect_ratio = Map.get(manifest, "image_aspect_ratio")

    IO.puts("Starting storyboard scene #{scene_id}")

    try do
      case Replicate.start(prompt, prediction_options(model, aspect_ratio)) do
        {:ok, prediction} ->
          await_and_download_scene(scene_id, prediction.id, output_path, timeout)

        {:error, reason} ->
          IO.puts("Scene #{scene_id} failed to start: #{inspect(reason)}")
          %{id: scene_id, prediction_id: nil, path: output_path, status: :error}
      end
    rescue
      exception ->
        IO.puts("Scene #{scene_id} crashed: #{Exception.message(exception)}")
        %{id: scene_id, prediction_id: nil, path: output_path, status: :error}
    catch
      kind, reason ->
        IO.puts("Scene #{scene_id} crashed: #{kind} #{inspect(reason)}")
        %{id: scene_id, prediction_id: nil, path: output_path, status: :error}
    end
  end

  defp generate_scene_video(scene, manifest, manifest_dir, timeout) do
    scene_id = scene_id(scene)
    output_path = Path.join(manifest_dir, "#{scene_id}.mp4")
    prompt = full_video_prompt(manifest, scene)
    model = Map.fetch!(manifest, "video_model")

    IO.puts("Starting storyboard video scene #{scene_id}")

    try do
      with {:ok, start_time, end_time} <- scene_timing(scene),
           {:ok, image_url} <- ensure_scene_image_url(scene_id, manifest_dir),
           {:ok, audio_url} <-
             ensure_scene_audio_url(scene_id, manifest_dir, start_time, end_time - start_time),
           {:ok, prediction} <-
             Replicate.start(
               prompt,
               video_prediction_options(
                 model,
                 image_url,
                 audio_url,
                 scene_video_duration_seconds(end_time - start_time)
               )
             ) do
        await_and_download_video(scene_id, prediction.id, output_path, timeout)
      else
        {:error, reason} ->
          IO.puts("Scene #{scene_id} failed to start video: #{inspect(reason)}")
          %{id: scene_id, prediction_id: nil, path: output_path, status: :error}
      end
    rescue
      exception ->
        IO.puts("Scene #{scene_id} video crashed: #{Exception.message(exception)}")
        %{id: scene_id, prediction_id: nil, path: output_path, status: :error}
    catch
      kind, reason ->
        IO.puts("Scene #{scene_id} video crashed: #{kind} #{inspect(reason)}")
        %{id: scene_id, prediction_id: nil, path: output_path, status: :error}
    end
  end

  defp await_and_download_scene(scene_id, prediction_id, output_path, timeout) do
    case Replicate.await(prediction_id, timeout) do
      {:ok, prediction} ->
        with {:ok, image_url} <- output_url(prediction.output),
             {:ok, path} <- download_image(image_url, output_path) do
          IO.puts("Scene #{scene_id} complete: #{path}")
          %{id: scene_id, prediction_id: prediction_id, path: path, status: :ok}
        else
          {:error, reason} ->
            IO.puts(
              "Scene #{scene_id} failed after prediction #{prediction_id}: #{inspect(reason)}"
            )

            %{id: scene_id, prediction_id: prediction_id, path: output_path, status: :error}
        end

      {:error, reason} ->
        IO.puts("Scene #{scene_id} failed while awaiting #{prediction_id}: #{inspect(reason)}")
        %{id: scene_id, prediction_id: prediction_id, path: output_path, status: :error}
    end
  end

  defp await_and_download_video(scene_id, prediction_id, output_path, timeout) do
    case Replicate.await(prediction_id, timeout) do
      {:ok, prediction} ->
        with {:ok, video_url} <- output_url(prediction.output),
             {:ok, path} <- download_video(video_url, output_path) do
          IO.puts("Scene #{scene_id} complete: #{path}")
          %{id: scene_id, prediction_id: prediction_id, path: path, status: :ok}
        else
          {:error, reason} ->
            IO.puts(
              "Scene #{scene_id} failed after prediction #{prediction_id}: #{inspect(reason)}"
            )

            %{id: scene_id, prediction_id: prediction_id, path: output_path, status: :error}
        end

      {:error, reason} ->
        IO.puts("Scene #{scene_id} failed while awaiting #{prediction_id}: #{inspect(reason)}")
        %{id: scene_id, prediction_id: prediction_id, path: output_path, status: :error}
    end
  end

  defp resize_scene_frame(scene, manifest_dir, frames_dir) do
    scene_id = scene_id(scene)
    input_path = Path.join(manifest_dir, "#{scene_id}.png")
    output_path = Path.join(frames_dir, "#{scene_id}.png")

    if File.exists?(input_path) do
      IO.puts("Resizing storyboard scene #{scene_id}")

      case System.cmd("ffmpeg", resize_args(input_path, output_path), stderr_to_stdout: true) do
        {_output, 0} ->
          IO.puts("Scene #{scene_id} resized: #{output_path}")
          %{id: scene_id, path: output_path, status: :ok}

        {output, code} ->
          IO.puts("Scene #{scene_id} resize failed (#{code}): #{String.trim(output)}")
          %{id: scene_id, path: output_path, status: :error}
      end
    else
      IO.puts("Scene #{scene_id} resize skipped: missing #{input_path}")
      %{id: scene_id, path: output_path, status: :error}
    end
  end

  defp resize_args(input_path, output_path) do
    filter =
      "scale=#{@frame_width}:#{@frame_height}:force_original_aspect_ratio=decrease," <>
        "pad=#{@frame_width}:#{@frame_height}:(ow-iw)/2:(oh-ih)/2:color=black"

    [
      "-y",
      "-i",
      input_path,
      "-vf",
      filter,
      "-frames:v",
      "1",
      output_path
    ]
  end

  defp manifest_scenes(manifest, opts, prompt_key) do
    only_ids = scene_id_set(Keyword.get(opts, :only, []))
    except_ids = scene_id_set(Keyword.get(opts, :except, []))

    manifest
    |> Map.get("scenes", [])
    |> Enum.filter(fn scene -> present?(scene[prompt_key]) end)
    |> Enum.filter(fn scene ->
      scene_id = scene_id(scene)

      (MapSet.size(only_ids) == 0 or MapSet.member?(only_ids, scene_id)) and
        not MapSet.member?(except_ids, scene_id)
    end)
  end

  defp scene_id_set(ids) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp scene_id_set(_ids), do: MapSet.new()

  defp prediction_options(model, nil), do: [model: model]
  defp prediction_options(model, aspect_ratio), do: [model: model, aspect_ratio: aspect_ratio]

  defp video_prediction_options(model, image_url, audio_url, duration) do
    [
      model: model,
      reference_images: [image_url],
      reference_audios: [audio_url],
      aspect_ratio: "9:16",
      duration: duration,
      resolution: "720p",
      generate_audio: false
    ]
  end

  defp read_manifest(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp full_prompt(manifest, scene) do
    style_prompt = Map.get(manifest, "style_prompt", "")
    image_prompt = scene["image_prompt"]

    combine_prompt(style_prompt, image_prompt)
  end

  defp full_video_prompt(manifest, scene) do
    style_prompt =
      manifest
      |> video_style_prompt()

    video_prompt = scene["video_prompt"]

    combine_prompt(style_prompt, video_prompt)
  end

  defp combine_prompt(style_prompt, prompt) do
    style_prompt =
      style_prompt
      |> to_string()
      |> String.trim()

    prompt =
      prompt
      |> to_string()
      |> String.trim()

    if style_prompt == "" do
      prompt
    else
      style_prompt <> "\n\n" <> prompt
    end
  end

  defp video_style_prompt(manifest) do
    case Map.get(manifest, "video_style_prompt") do
      value when is_binary(value) ->
        if present?(value) do
          value
        else
          Map.get(manifest, "style_prompt", "")
        end

      _ ->
        Map.get(manifest, "style_prompt", "")
    end
  end

  defp output_url(%{"urls" => [url | _]}) when is_binary(url), do: {:ok, url}
  defp output_url(_output), do: {:error, :missing_output_url}

  defp download_image(url, output_path) do
    download_file(url, output_path, :image_download_failed)
  end

  defp download_video(url, output_path) do
    download_file(url, output_path, :video_download_failed)
  end

  defp download_file(url, output_path, error_tag) do
    case Req.get(url, receive_timeout: @download_timeout, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case File.write(output_path, body) do
          :ok -> {:ok, output_path}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {error_tag, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_scene_image_url(scene_id, manifest_dir) do
    source_path = Path.join(manifest_dir, "#{scene_id}.png")
    public_path = "images/storyboard/#{scene_id}.png"
    ensure_public_file(source_path, public_path)
  end

  defp ensure_scene_audio_url(scene_id, manifest_dir, start_time, duration) do
    source_path = Path.join(manifest_dir, "song.mp3")
    clips_dir = Path.join(manifest_dir, "clips_audio")
    clip_path = Path.join(clips_dir, "#{scene_id}.mp3")
    public_path = "audio/clips/#{scene_id}.mp3"

    with :ok <- ensure_existing_file(source_path),
         :ok <- File.mkdir_p(clips_dir),
         :ok <- slice_scene_audio(source_path, clip_path, start_time, duration),
         {:ok, url} <- ensure_public_file(clip_path, public_path) do
      {:ok, url}
    end
  end

  defp ensure_public_file(source_path, public_path) do
    destination_path = public_static_path(public_path)

    with :ok <- ensure_existing_file(source_path),
         :ok <- File.mkdir_p(Path.dirname(destination_path)),
         :ok <- copy_public_file(source_path, destination_path) do
      {:ok, public_static_url(public_path)}
    end
  end

  defp ensure_existing_file(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, {:missing_file, path}}
    end
  end

  defp copy_public_file(source_path, destination_path) do
    if Path.expand(source_path) == Path.expand(destination_path) do
      :ok
    else
      File.cp(source_path, destination_path)
    end
  end

  defp slice_scene_audio(source_path, clip_path, start_time, duration) do
    case System.cmd(
           "ffmpeg",
           [
             "-y",
             "-i",
             source_path,
             "-ss",
             format_seconds(start_time),
             "-t",
             format_seconds(duration),
             "-c",
             "copy",
             clip_path
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, {:ffmpeg_failed, code, String.trim(output)}}
    end
  end

  defp public_static_path(public_path) do
    Path.join(Application.app_dir(:froth, "priv/static"), public_path)
  end

  defp public_static_url(public_path) do
    @static_base_url <> "/" <> String.trim_leading(public_path, "/")
  end

  defp scene_timing(scene) do
    with {:ok, start_time} <- scene_time(scene["start"]),
         {:ok, end_time} <- scene_time(scene["end"]),
         true <- end_time > start_time do
      {:ok, start_time, end_time}
    else
      false -> {:error, :invalid_scene_timing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scene_time(value) when is_integer(value), do: {:ok, value * 1.0}
  defp scene_time(value) when is_float(value), do: {:ok, value}

  defp scene_time(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {time, ""} -> {:ok, time}
      _ -> {:error, :invalid_scene_timing}
    end
  end

  defp scene_time(_value), do: {:error, :invalid_scene_timing}

  defp scene_video_duration_seconds(duration) when is_number(duration) do
    duration
    |> Kernel.*(1.0)
    |> Float.ceil()
    |> trunc()
    |> min(15)
    |> max(5)
  end

  defp format_seconds(value) when is_number(value) do
    value
    |> Kernel.*(1.0)
    |> :erlang.float_to_binary(decimals: 3)
  end

  defp scene_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp scene_id(%{"id" => id}), do: to_string(id)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_nil(value), do: false
  defp present?(value), do: value |> to_string() |> String.trim() != ""

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
