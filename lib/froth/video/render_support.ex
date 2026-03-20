defmodule Froth.Video.RenderSupport do
  @moduledoc false

  @default_width 1080
  @default_height 1920
  @default_fps 24

  def prepare_recording(html, opts) when is_binary(html) and is_list(opts) do
    duration_s = Keyword.fetch!(opts, :duration_s) |> normalize_duration()
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    fps = Keyword.get(opts, :fps, @default_fps)
    keep_frames? = Keyword.get(opts, :keep_frames, false)
    render_id = Keyword.get(opts, :render_id, render_id())
    render_root = render_root()
    frames_dir = Path.join(render_root, "#{render_id}-frames")
    output_path = Keyword.get(opts, :output_path, Path.join(render_root, "#{render_id}.mp4"))
    html_path = Path.join(frames_dir, "episode.html")
    browser_boot_timeout_ms = Keyword.get(opts, :browser_boot_timeout_ms, 45_000)

    with {:ok, audio_path, cleanup_audio?} <- ensure_audio_path(opts, render_id),
         :ok <- File.mkdir_p(frames_dir),
         :ok <- File.write(html_path, html) do
      {:ok,
       %{
         render_id: render_id,
         render_root: render_root,
         frames_dir: frames_dir,
         output_path: output_path,
         html_path: html_path,
         audio_path: audio_path,
         cleanup_audio?: cleanup_audio?,
         keep_frames?: keep_frames?,
         duration_s: duration_s,
         width: width,
         height: height,
         fps: fps,
         frame_count: frame_count(duration_s, fps),
         browser_boot_timeout_ms: browser_boot_timeout_ms
       }}
    else
      {:error, _reason} = error ->
        cleanup_partial_recording(frames_dir, opts, render_id)
        error
    end
  end

  def cleanup_recording(plan) when is_map(plan) do
    unless plan.keep_frames? do
      File.rm_rf(plan.frames_dir)
    end

    if plan.cleanup_audio? do
      File.rm(plan.audio_path)
    end

    :ok
  end

  def boot_browser(browser_id, plan) when is_map(plan) do
    with :ok <- Froth.Browser.set_viewport(browser_id, width: plan.width, height: plan.height),
         :ok <-
           Froth.Browser.navigate(
             browser_id,
             file_url(plan.html_path) <> "?record=1",
             timeout_ms: plan.browser_boot_timeout_ms
           ),
         :ok <- wait_for_video_api(browser_id, plan.browser_boot_timeout_ms) do
      :ok
    end
  end

  def render_frame_range(browser_id, plan, from_frame, to_frame, opts \\ [])
      when is_map(plan) and is_integer(from_frame) and is_integer(to_frame) and is_list(opts) do
    on_frame = Keyword.get(opts, :on_frame, fn _frame_index, _frame_total -> :ok end)
    frame_total = max(to_frame - from_frame + 1, 0)

    Enum.reduce_while(from_frame..to_frame, :ok, fn frame_index, _acc ->
      seconds = frame_index / plan.fps
      frame_path = frame_path(plan.frames_dir, frame_index)

      result =
        with {:ok, _state} <- Froth.Browser.eval(browser_id, render_script(seconds)),
             {:ok, _path} <- Froth.Browser.screenshot(browser_id, path: frame_path),
             :ok <- on_frame.(frame_index, frame_total) do
          :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def mux_frames(plan, opts \\ []) when is_map(plan) and is_list(opts) do
    preset = Keyword.get(opts, :preset, "fast")
    crf = Keyword.get(opts, :crf, 23)
    audio_bitrate = Keyword.get(opts, :audio_bitrate, "192k")
    input_pattern = Path.join(plan.frames_dir, "frame_%06d.png")

    args = [
      "-y",
      "-framerate",
      to_string(plan.fps),
      "-i",
      input_pattern,
      "-i",
      plan.audio_path,
      "-c:v",
      "libx264",
      "-preset",
      preset,
      "-crf",
      to_string(crf),
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-b:a",
      audio_bitrate,
      "-shortest",
      plan.output_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, {:ffmpeg_failed, code, output}}
    end
  end

  def verify_frames(plan) when is_map(plan) do
    missing =
      0..(plan.frame_count - 1)
      |> Enum.reject(fn frame_index -> File.exists?(frame_path(plan.frames_dir, frame_index)) end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_frames, missing}}
    end
  end

  def frame_path(frames_dir, frame_index)
      when is_binary(frames_dir) and is_integer(frame_index) do
    Path.join(frames_dir, "frame_#{pad_frame(frame_index)}.png")
  end

  def frame_count(duration_s, fps) do
    duration_s
    |> Kernel.*(fps)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  def render_root do
    Application.get_env(:froth, Froth.Video, [])
    |> Keyword.get(:render_dir, Path.expand("tmp/video-renders"))
    |> Path.expand()
  end

  def video_config do
    Application.get_env(:froth, Froth.Video, [])
  end

  defp file_url(path) when is_binary(path) do
    "file://" <> Path.expand(path)
  end

  defp wait_for_video_api(browser_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_video_api(browser_id, deadline)
  end

  defp do_wait_for_video_api(browser_id, deadline) do
    case Froth.Browser.eval(
           browser_id,
           "!!(window.FrothVideo && typeof window.FrothVideo.renderAt === 'function')"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        continue_waiting_for_video_api(browser_id, deadline)

      {:error, _reason} ->
        continue_waiting_for_video_api(browser_id, deadline)
    end
  end

  defp continue_waiting_for_video_api(browser_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :content_boot_timeout}
    else
      Process.sleep(100)
      do_wait_for_video_api(browser_id, deadline)
    end
  end

  defp render_script(seconds) do
    encoded_seconds = :erlang.float_to_binary(seconds, decimals: 6)
    "window.FrothVideo.renderAt(#{encoded_seconds})"
  end

  defp ensure_audio_path(opts, render_id) do
    cond do
      audio_path = Keyword.get(opts, :audio_path) ->
        audio_path = Path.expand(audio_path)

        if File.exists?(audio_path),
          do: {:ok, audio_path, false},
          else: {:error, :audio_not_found}

      audio_url = Keyword.get(opts, :audio_url) ->
        download_audio(audio_url, render_id)

      true ->
        {:error, :missing_audio_input}
    end
  end

  defp download_audio(audio_url, render_id) when is_binary(audio_url) do
    path = Path.join(render_root(), "#{render_id}.mp3")

    :ok = File.mkdir_p(render_root())

    case Req.get(audio_url, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: body}} ->
        case File.write(path, body) do
          :ok -> {:ok, path, true}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status}} ->
        {:error, {:audio_download_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_partial_recording(frames_dir, opts, render_id) do
    File.rm_rf(frames_dir)

    if Keyword.has_key?(opts, :audio_url) do
      File.rm(Path.join(render_root(), "#{render_id}.mp3"))
    end

    :ok
  end

  defp normalize_duration(duration) when is_integer(duration), do: duration * 1.0
  defp normalize_duration(duration) when is_float(duration), do: duration

  defp normalize_duration(duration) when is_binary(duration) do
    case Float.parse(duration) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp normalize_duration(_duration), do: 0.0

  defp pad_frame(frame_index) do
    frame_index
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp render_id do
    Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end
