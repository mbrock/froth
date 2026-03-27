defmodule Froth.Cast do
  @moduledoc """
  Convert asciinema `.cast` recordings into standalone HTML or MP4 video.

  HTML is the primary artifact: it opens directly in a browser or Telegram web
  view, keeps the recording interactive, and avoids the slow screenshot-based
  video path. MP4 export is still available when a plain video file is needed.
  """

  alias Froth.Cast.{Parser, Recording, Template, Theme}
  alias Froth.Video
  alias Froth.Video.RenderSupport

  @default_fps 30
  @default_speed 1.0
  @default_font_size 24
  @default_outer_padding 48
  @default_terminal_padding 28
  @default_chrome_height 56
  @default_lead_out_s 0.75

  @allowed_video_opts [:keep_frames, :preset, :crf, :audio_bitrate, :browser_boot_timeout_ms]

  def parse_file(path) when is_binary(path), do: Parser.parse_file(path)

  def render_html(cast, opts \\ [])

  def render_html(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, prepared} <- prepare_recording(path, opts) do
      {:ok, prepared.html}
    end
  end

  def render_html(%Recording{} = recording, opts) when is_list(opts) do
    with {:ok, prepared} <- prepare_recording(recording, opts) do
      {:ok, prepared.html}
    end
  end

  def write_html(cast, opts \\ [])

  def write_html(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, prepared} <- prepare_recording(path, opts),
         output_path <-
           resolve_export_path(path, Keyword.get(opts, :output_path), prepared.render_id, ".html"),
         :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- File.write(output_path, prepared.html) do
      {:ok,
       %{
         output_path: output_path,
         duration_s: prepared.duration_s,
         width: prepared.width,
         height: prepared.height,
         title: prepared.recording.title,
         recording: prepared.recording
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def write_html(%Recording{} = recording, opts) when is_list(opts) do
    with {:ok, prepared} <- prepare_recording(recording, opts),
         output_path <-
           resolve_export_path(
             Keyword.get(opts, :source_path),
             Keyword.get(opts, :output_path),
             prepared.render_id,
             ".html"
           ),
         :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- File.write(output_path, prepared.html) do
      {:ok,
       %{
         output_path: output_path,
         duration_s: prepared.duration_s,
         width: prepared.width,
         height: prepared.height,
         title: prepared.recording.title,
         recording: prepared.recording
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare_recording(cast, opts \\ [])

  def prepare_recording(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, recording} <- parse_file(path) do
      prepare_recording(recording, Keyword.put_new(opts, :source_path, path))
    end
  end

  def prepare_recording(%Recording{} = recording, opts) when is_list(opts) do
    with {:ok, fps} <- positive_integer(Keyword.get(opts, :fps, @default_fps), :fps),
         {:ok, speed} <- positive_float(Keyword.get(opts, :speed, @default_speed), :speed),
         {:ok, font_size} <-
           positive_integer(Keyword.get(opts, :font_size, @default_font_size), :font_size),
         {:ok, lead_out_s} <-
           non_negative_float(Keyword.get(opts, :lead_out_s, @default_lead_out_s), :lead_out_s),
         {:ok, idle_time_limit} <-
           optional_non_negative_float(
             Keyword.get(opts, :idle_time_limit, recording.idle_time_limit),
             :idle_time_limit
           ),
         {:ok, theme} <- Theme.resolve(recording.theme, Keyword.get(opts, :theme)) do
      normalized_events = normalize_events(recording.events, idle_time_limit, speed)

      normalized_duration =
        normalize_duration(recording, normalized_events, idle_time_limit, speed)

      duration_s = max(normalized_duration + lead_out_s, lead_out_s)
      title = resolve_title(recording, opts)
      window_chrome? = not Keyword.get(opts, :plain, false)
      chrome_height = if(window_chrome?, do: @default_chrome_height, else: 0)

      cell_width = Float.round(font_size * 0.615, 3)
      cell_height = Float.round(font_size * 1.45, 3)
      outer_padding = Keyword.get(opts, :outer_padding, @default_outer_padding)
      terminal_padding = Keyword.get(opts, :terminal_padding, @default_terminal_padding)

      {width, height} =
        resolve_dimensions(
          recording,
          opts,
          cell_width,
          cell_height,
          outer_padding,
          terminal_padding,
          chrome_height
        )

      render_id = Keyword.get(opts, :render_id, default_render_id())

      output_path =
        resolve_export_path(
          Keyword.get(opts, :source_path),
          Keyword.get(opts, :output_path),
          render_id,
          ".mp4"
        )

      normalized_recording = %{
        recording
        | title: title,
          theme: theme,
          duration_s: duration_s,
          events: normalized_events
      }

      html =
        Template.render(normalized_recording,
          title: title,
          font_size: font_size,
          cell_width: cell_width,
          cell_height: cell_height,
          terminal_padding: terminal_padding,
          outer_padding: outer_padding,
          chrome_height: chrome_height,
          window_chrome?: window_chrome?
        )

      record_opts =
        [
          duration_s: duration_s,
          fps: fps,
          width: width,
          height: height,
          output_path: output_path,
          render_id: sanitize_id(render_id)
        ] ++ Keyword.take(opts, @allowed_video_opts)

      {:ok,
       %{
         recording: normalized_recording,
         html: html,
         duration_s: duration_s,
         fps: fps,
         width: width,
         height: height,
         render_id: render_id,
         output_path: output_path,
         record_opts: record_opts
       }}
    end
  end

  def to_video(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, prepared} <- prepare_recording(path, opts),
         :ok <- ensure_browser_runtime_started(),
         {:ok, audio_path} <- create_silent_audio(prepared.duration_s, prepared.render_id),
         {:ok, output_path} <- record(prepared, audio_path) do
      {:ok,
       %{
         output_path: output_path,
         duration_s: prepared.duration_s,
         fps: prepared.fps,
         width: prepared.width,
         height: prepared.height,
         title: prepared.recording.title,
         recording: prepared.recording
       }}
    end
  end

  defp record(prepared, audio_path) do
    try do
      prepared.record_opts
      |> Keyword.put(:audio_path, audio_path)
      |> then(&Video.record(prepared.html, &1))
    after
      File.rm(audio_path)
    end
  end

  defp normalize_events(events, idle_time_limit, speed) do
    {normalized, _raw_at, _adjusted_at} =
      Enum.reduce(events, {[], 0.0, 0.0}, fn event,
                                             {acc, previous_raw_at, previous_adjusted_at} ->
        raw_delta = max(event.at - previous_raw_at, 0.0)
        adjusted_delta = limit_idle(raw_delta, idle_time_limit) / speed
        adjusted_at = previous_adjusted_at + adjusted_delta

        normalized_event = %{event | at: adjusted_at}
        {[normalized_event | acc], event.at, adjusted_at}
      end)

    Enum.reverse(normalized)
  end

  defp normalize_duration(recording, normalized_events, idle_time_limit, speed) do
    last_raw_at = last_event_time(recording.events)
    last_adjusted_at = last_event_time(normalized_events)
    raw_duration = max(recording.duration_s, last_raw_at)
    tail = max(raw_duration - last_raw_at, 0.0)
    last_adjusted_at + limit_idle(tail, idle_time_limit) / speed
  end

  defp resolve_dimensions(
         recording,
         opts,
         cell_width,
         cell_height,
         outer_padding,
         terminal_padding,
         chrome_height
       ) do
    base_width =
      even(outer_padding * 2 + terminal_padding * 2 + recording.max_cols * cell_width)

    base_height =
      even(
        outer_padding * 2 + terminal_padding * 2 + chrome_height +
          recording.max_rows * cell_height
      )

    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)

    cond do
      is_integer(width) and width > 0 and is_integer(height) and height > 0 ->
        {even(width), even(height)}

      is_integer(width) and width > 0 ->
        scale = width / base_width
        {even(width), even(base_height * scale)}

      is_integer(height) and height > 0 ->
        scale = height / base_height
        {even(base_width * scale), even(height)}

      true ->
        {base_width, base_height}
    end
  end

  defp resolve_title(recording, opts) do
    case Keyword.get(opts, :title) || recording.title || recording.command ||
           source_basename(opts) do
      nil -> "Terminal Recording"
      title -> title
    end
  end

  defp resolve_export_path(source_path, output_path, render_id, extension) do
    output =
      output_path ||
        case source_path do
          nil ->
            Path.join(RenderSupport.render_root(), "#{sanitize_id(render_id)}#{extension}")

          path ->
            path
            |> Path.expand()
            |> Path.rootname()
            |> Kernel.<>(extension)
        end

    Path.expand(output)
  end

  defp create_silent_audio(duration_s, render_id) do
    duration_s = max(duration_s, 0.1)
    root = RenderSupport.render_root()
    path = Path.join(root, "#{sanitize_id(render_id)}-silent.wav")

    with :ok <- File.mkdir_p(root) do
      case System.cmd(
             "ffmpeg",
             [
               "-y",
               "-f",
               "lavfi",
               "-i",
               "anullsrc=channel_layout=stereo:sample_rate=48000",
               "-t",
               format_float(duration_s),
               "-c:a",
               "pcm_s16le",
               path
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          {:ok, path}

        {output, code} ->
          {:error, {:silent_audio_failed, code, output}}
      end
    end
  end

  defp ensure_browser_runtime_started do
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:req)

    case Process.whereis(Froth.Browser.Supervisor) do
      nil ->
        case Froth.Browser.Supervisor.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:browser_runtime_failed, reason}}
        end

      _pid ->
        :ok
    end
  end

  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value, name), do: {:error, {:invalid_option, name, value}}

  defp positive_float(value, _name) when is_float(value) and value > 0, do: {:ok, value}
  defp positive_float(value, _name) when is_integer(value) and value > 0, do: {:ok, value * 1.0}
  defp positive_float(value, name), do: {:error, {:invalid_option, name, value}}

  defp non_negative_float(value, _name) when is_float(value) and value >= 0, do: {:ok, value}

  defp non_negative_float(value, _name) when is_integer(value) and value >= 0,
    do: {:ok, value * 1.0}

  defp non_negative_float(value, name), do: {:error, {:invalid_option, name, value}}

  defp optional_non_negative_float(nil, _name), do: {:ok, nil}
  defp optional_non_negative_float(value, name), do: non_negative_float(value, name)

  defp limit_idle(delta, nil), do: delta
  defp limit_idle(delta, idle_time_limit), do: min(delta, idle_time_limit)

  defp last_event_time([]), do: 0.0
  defp last_event_time(events), do: events |> List.last() |> Map.fetch!(:at)

  defp format_float(value) do
    :erlang.float_to_binary(value, decimals: 3)
  end

  defp default_render_id do
    Froth.Tasks.generate_id("cast")
  end

  defp source_basename(opts) do
    case Keyword.get(opts, :source_path) do
      nil -> nil
      path -> Path.basename(path)
    end
  end

  defp sanitize_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]+/, "-")
  end

  defp even(value) do
    value
    |> round()
    |> max(2)
    |> then(fn rounded -> if rem(rounded, 2) == 0, do: rounded, else: rounded + 1 end)
  end
end
