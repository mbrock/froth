defmodule Mix.Tasks.Froth.Cast do
  @moduledoc """
  Convert an asciinema `.cast` recording into a standalone HTML player or MP4.

  HTML is the default output because it's fast, self-contained, and opens
  directly in browsers or Telegram web views.

      mix froth.cast demo.cast
      mix froth.cast demo.cast --out /tmp/demo.html
      mix froth.cast demo.cast --video --out /tmp/demo.mp4
      mix froth.cast demo.cast --theme dracula --speed 1.5 --plain
  """
  @shortdoc "Render asciinema cast files to HTML or MP4"

  use Mix.Task

  alias Froth.Cast
  alias Froth.Cast.Theme

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          video: :boolean,
          fps: :integer,
          speed: :float,
          idle_time_limit: :float,
          font_size: :integer,
          width: :integer,
          height: :integer,
          title: :string,
          theme: :string,
          lead_out: :float,
          keep_frames: :boolean,
          plain: :boolean,
          preset: :string,
          crf: :integer
        ],
        aliases: [o: :out, t: :title]
      )

    if invalid != [] do
      Mix.raise("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    end

    cast_path =
      case positional do
        [path] -> Path.expand(path)
        [] -> Mix.raise("Usage: mix froth.cast <path.cast> [options]")
        _ -> Mix.raise("Expected exactly one .cast input path")
      end

    unless File.exists?(cast_path) do
      Mix.raise("Cast file not found: #{cast_path}")
    end

    render_opts =
      [
        output_path: opts[:out],
        fps: opts[:fps],
        speed: opts[:speed],
        idle_time_limit: opts[:idle_time_limit],
        font_size: opts[:font_size],
        width: opts[:width],
        height: opts[:height],
        title: opts[:title],
        theme: opts[:theme],
        lead_out_s: opts[:lead_out],
        keep_frames: opts[:keep_frames],
        plain: opts[:plain],
        preset: opts[:preset],
        crf: opts[:crf]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false end)

    Mix.shell().info(start_message(cast_path, opts[:video]))

    result =
      if opts[:video] do
        Cast.to_video(cast_path, render_opts)
      else
        Cast.write_html(cast_path, render_opts)
      end

    case result do
      {:ok, %{output_path: output_path, duration_s: duration_s, width: width, height: height}} ->
        Mix.shell().info(finish_message(output_path, duration_s, width, height, opts[:video]))

      {:error, {:unknown_theme, theme}} ->
        Mix.raise(
          "Unknown theme #{inspect(theme)}. Available presets: #{Enum.join(Theme.preset_names(), ", ")}"
        )

      {:error, reason} ->
        Mix.raise("Cast render failed: #{inspect(reason)}")
    end
  end

  defp start_message(cast_path, true), do: "Rendering MP4 from #{cast_path}..."
  defp start_message(cast_path, _html), do: "Rendering standalone HTML from #{cast_path}..."

  defp finish_message(output_path, duration_s, width, height, true) do
    "MP4 written: #{output_path} (#{width}x#{height}, #{Float.round(duration_s, 2)}s)"
  end

  defp finish_message(output_path, duration_s, width, height, _html) do
    "HTML written: #{output_path} (#{width}x#{height}, #{Float.round(duration_s, 2)}s)"
  end
end
