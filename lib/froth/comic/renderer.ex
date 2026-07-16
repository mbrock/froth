defmodule Froth.Comic.Renderer do
  @moduledoc false

  @spec svg(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def svg(layout, opts \\ []) do
    asset_root = Keyword.get(opts, :asset_root, default_asset_root())

    with {:ok, font} <- read_asset(Path.join(asset_root, "fonts/comic.ttf")),
         {:ok, avatars} <-
           load_named_assets(
             asset_root,
             "avatars",
             ~w(waf glenda pedagog rainbow tux)
           ),
         {:ok, backdrops} <-
           load_named_assets(
             asset_root,
             "backdrops",
             ~w(field pastoral room8bs)
           ) do
      {:ok, render_svg(layout, font, avatars, backdrops, :full)}
    end
  end

  @spec png(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def png(layout, opts \\ []) do
    asset_root = Keyword.get(opts, :asset_root, default_asset_root())

    with {:ok, font} <- read_asset(Path.join(asset_root, "fonts/comic.ttf")),
         {:ok, avatars} <-
           load_named_assets(
             asset_root,
             "avatars",
             ~w(waf glenda pedagog rainbow tux)
           ),
         {:ok, backdrops} <-
           load_named_assets(
             asset_root,
             "backdrops",
             ~w(field pastoral room8bs)
           ),
         foreground_svg <-
           render_svg(layout, font, avatars, backdrops, :foreground),
         {:ok, foreground_png} <- rasterize(foreground_svg),
         {:ok, base} <- compose_art(layout, avatars, backdrops),
         {:ok, png} <- composite_png(base, foreground_png) do
      {:ok, png}
    end
  end

  defp render_svg(layout, font, avatars, backdrops, mode) do
    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{layout.width}" height="#{layout.height}" viewBox="0 0 #{layout.width} #{layout.height}">),
      "<defs>",
      "<style>",
      "@font-face{font-family:'Comic Chat';src:url(data:font/ttf;base64,#{Base.encode64(font)}) format('truetype');}",
      ".comic{font-family:'Comic Chat','Comic Sans MS',sans-serif;fill:#111}.outline{stroke:#111;stroke-width:4;stroke-linejoin:round}",
      "</style>",
      panel_clips(layout.panels),
      "</defs>",
      if(mode == :full,
        do: ~s(<rect width="100%" height="100%" fill="#ece8dc"/>),
        else: []
      ),
      Enum.map(layout.panels, &panel(&1, avatars, backdrops, mode)),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  defp panel_clips(panels) do
    Enum.map(panels, fn panel ->
      ~s(<clipPath id="panel-clip-#{panel.id}"><rect x="#{panel.x}" y="#{panel.y}" width="#{panel.width}" height="#{panel.height}"/></clipPath>)
    end)
  end

  defp panel(panel, avatars, backdrops, mode) do
    backdrop = Map.fetch!(backdrops, panel.backdrop)

    [
      ~s|<g id="panel-#{panel.id}" clip-path="url(#panel-clip-#{panel.id})">|,
      if(mode == :full,
        do: [
          ~s(<rect x="#{panel.x}" y="#{panel.y}" width="#{panel.width}" height="#{panel.height}" fill="#fffdf4"/>),
          ~s(<image href="data:image/png;base64,#{Base.encode64(backdrop)}" x="#{panel.x}" y="#{panel.y}" width="#{panel.width}" height="#{panel.height}" preserveAspectRatio="xMidYMid slice" opacity="0.26"/>)
        ],
        else: []
      ),
      ~s(<rect x="#{panel.x}" y="#{panel.y}" width="#{panel.width}" height="#{panel.height}" fill="#fffaf0" opacity="0.18"/>),
      if(mode == :full,
        do: Enum.map(panel.characters, &character(&1, avatars)),
        else: Enum.map(panel.characters, &expression_mark/1)
      ),
      Enum.map(panel.balloons, &balloon/1),
      ~s(<rect x="#{panel.x + 2}" y="#{panel.y + 2}" width="#{panel.width - 4}" height="#{panel.height - 4}" fill="none" stroke="#111" stroke-width="5"/>),
      "</g>"
    ]
  end

  defp character(character, avatars) do
    asset = Map.fetch!(avatars, character.avatar)

    [
      ~s(<image href="data:image/png;base64,#{Base.encode64(asset)}" x="#{character.x}" y="#{character.y}" width="#{character.width}" height="#{character.height}" preserveAspectRatio="xMidYMax meet"/>),
      expression_mark(character)
    ]
  end

  defp expression_mark(%{semantics: %{emotion: emotion}} = character)
       when emotion in [:happy, :laughing] do
    x = character.center_x
    y = character.y + 28

    [
      ~s(<path d="M #{x - 55} #{y} l -18 -12 M #{x + 55} #{y} l 18 -12 M #{x - 47} #{y - 18} l -10 -20 M #{x + 47} #{y - 18} l 10 -20" fill="none" stroke="#111" stroke-width="4" stroke-linecap="round"/>),
      if(character.semantics.gesture == :wave,
        do:
          ~s(<text x="#{x + 54}" y="#{y + 24}" class="comic" font-size="30">♪</text>),
        else: []
      )
    ]
  end

  defp expression_mark(%{semantics: %{emotion: :angry}} = character) do
    x = character.center_x + 45
    y = character.y + 12

    ~s(<path d="M #{x} #{y} l 10 -13 l 8 13 l 11 -13" fill="none" stroke="#111" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>)
  end

  defp expression_mark(%{semantics: %{emotion: :sad}} = character) do
    ~s(<path d="M #{character.center_x + 38} #{character.y + 38} q 10 14 0 27 q -10 -13 0 -27" fill="#8ed6f0" stroke="#111" stroke-width="2"/>)
  end

  defp expression_mark(%{semantics: %{emotion: emotion}} = character)
       when emotion in [:surprised, :scared] do
    ~s(<text x="#{character.center_x + 48}" y="#{character.y + 16}" class="comic" font-size="34" font-weight="700">!?</text>)
  end

  defp expression_mark(_character), do: []

  defp balloon(balloon) do
    [
      balloon_shape(balloon),
      balloon_tail(balloon),
      text(balloon)
    ]
  end

  defp balloon_shape(%{semantics: %{balloon: :shout}} = balloon) do
    x = balloon.x
    y = balloon.y
    w = balloon.width
    h = balloon.height - 8

    points = [
      {x + 6, y + div(h, 3)},
      {x, y + 4},
      {x + div(w, 5), y + 12},
      {x + div(w, 3), y},
      {x + div(w, 2), y + 10},
      {x + w - 8, y + 2},
      {x + w - 2, y + div(h, 3)},
      {x + w, y + h - 5},
      {x + div(w * 3, 4), y + h},
      {x + div(w, 2), y + h - 7},
      {x + 8, y + h}
    ]

    ~s(<polygon points="#{points(points)}" fill="#fff7c7" class="outline"/>)
  end

  defp balloon_shape(%{semantics: %{balloon: :action}} = balloon) do
    ~s(<rect x="#{balloon.x}" y="#{balloon.y}" width="#{balloon.width}" height="#{balloon.height - 8}" fill="#fff4b8" class="outline"/>)
  end

  defp balloon_shape(%{semantics: %{balloon: :think}} = balloon) do
    ~s(<rect x="#{balloon.x}" y="#{balloon.y}" width="#{balloon.width}" height="#{balloon.height - 8}" rx="#{div(balloon.height, 2)}" fill="white" class="outline"/>)
  end

  defp balloon_shape(%{semantics: %{balloon: :whisper}} = balloon) do
    ~s(<rect x="#{balloon.x}" y="#{balloon.y}" width="#{balloon.width}" height="#{balloon.height - 8}" rx="24" fill="white" stroke="#111" stroke-width="3" stroke-dasharray="9 7"/>)
  end

  defp balloon_shape(balloon) do
    ~s(<rect x="#{balloon.x}" y="#{balloon.y}" width="#{balloon.width}" height="#{balloon.height - 8}" rx="28" fill="white" class="outline"/>)
  end

  defp balloon_tail(%{semantics: %{balloon: :action}}), do: []

  defp balloon_tail(%{semantics: %{balloon: :think}} = balloon) do
    edge_x =
      clamp(balloon.speaker_x, balloon.x + 22, balloon.x + balloon.width - 22)

    y = balloon.y + balloon.height - 3
    mid_x = div(edge_x + balloon.speaker_x, 2)
    mid_y = div(y + balloon.speaker_y, 2)

    [
      ~s(<circle cx="#{edge_x}" cy="#{y}" r="9" fill="white" stroke="#111" stroke-width="3"/>),
      ~s(<circle cx="#{mid_x}" cy="#{mid_y}" r="6" fill="white" stroke="#111" stroke-width="3"/>),
      ~s(<circle cx="#{balloon.speaker_x}" cy="#{balloon.speaker_y}" r="3" fill="white" stroke="#111" stroke-width="2"/>)
    ]
  end

  defp balloon_tail(balloon) do
    edge_x =
      clamp(balloon.speaker_x, balloon.x + 22, balloon.x + balloon.width - 22)

    edge_y = balloon.y + balloon.height - 10
    spread = if(balloon.semantics.balloon == :whisper, do: 7, else: 13)

    ~s(<polygon points="#{edge_x - spread},#{edge_y - 3} #{edge_x + spread},#{edge_y - 3} #{balloon.speaker_x},#{balloon.speaker_y}" fill="white" stroke="#111" stroke-width="3" stroke-linejoin="round"/>)
  end

  defp text(balloon) do
    x = balloon.x + 21
    sender_y = balloon.y + 27
    text_y = sender_y + 27
    sender = xml_escape(balloon.sender)

    [
      ~s(<text x="#{x}" y="#{sender_y}" class="comic" font-size="17" font-weight="700">#{sender}</text>),
      ~s(<text x="#{x}" y="#{text_y}" class="comic" font-size="21">),
      balloon.lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        ~s(<tspan x="#{x}" dy="#{if(index == 0, do: 0, else: 24)}">#{xml_escape(line)}</tspan>)
      end),
      "</text>"
    ]
  end

  defp load_named_assets(root, directory, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      path = Path.join([root, directory, name <> ".png"])

      case read_asset(path) do
        {:ok, binary} -> {:cont, {:ok, Map.put(acc, name, binary)}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_asset(path) do
    case File.read(path) do
      {:ok, binary} ->
        {:ok, binary}

      {:error, reason} ->
        {:error,
         "cannot read comic asset #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp compose_art(layout, avatars, backdrops) do
    with {:ok, canvas} <-
           Image.new(layout.width, layout.height, color: "#ece8dc") do
      Enum.reduce_while(
        layout.panels,
        {:ok, canvas},
        fn panel, {:ok, image} ->
          with {:ok, backdrop} <-
                 Image.from_binary(Map.fetch!(backdrops, panel.backdrop)),
               {:ok, backdrop} <-
                 Image.thumbnail(
                   backdrop,
                   "#{panel.width}x#{panel.height}",
                   fit: :cover
                 ),
               {:ok, backdrop} <- Image.Math.multiply(backdrop, 0.32),
               {:ok, backdrop} <- Image.Math.add(backdrop, 173),
               {:ok, image} <-
                 Image.compose(image, backdrop, x: panel.x, y: panel.y),
               {:ok, image} <-
                 compose_characters(image, panel.characters, avatars) do
            {:cont, {:ok, image}}
          else
            error -> {:halt, error}
          end
        end
      )
    end
  end

  defp compose_characters(image, characters, avatars) do
    Enum.reduce_while(characters, {:ok, image}, fn character, {:ok, image} ->
      with {:ok, avatar} <-
             Image.from_binary(Map.fetch!(avatars, character.avatar)),
           {:ok, avatar} <-
             Image.thumbnail(
               avatar,
               "#{character.width}x#{character.height}",
               fit: :contain
             ),
           x = character.center_x - div(Image.width(avatar), 2),
           y = character.y + character.height - Image.height(avatar),
           {:ok, image} <- Image.compose(image, avatar, x: x, y: y) do
        {:cont, {:ok, image}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp composite_png(base, foreground_png) do
    token = System.unique_integer([:positive, :monotonic])
    base_path = Path.join(System.tmp_dir!(), "froth-comic-base-#{token}.png")

    foreground_path =
      Path.join(System.tmp_dir!(), "froth-comic-foreground-#{token}.png")

    output_path =
      Path.join(System.tmp_dir!(), "froth-comic-output-#{token}.png")

    try do
      with executable when is_binary(executable) <-
             System.find_executable("convert") ||
               {:error,
                "ImageMagick's convert executable is required to composite comics"},
           {:ok, _image} <- Image.write(base, base_path),
           :ok <- File.write(foreground_path, foreground_png),
           {_output, 0} <-
             System.cmd(
               executable,
               [
                 base_path,
                 foreground_path,
                 "-composite",
                 "-strip",
                 output_path
               ],
               stderr_to_stdout: true
             ),
           {:ok, png} <- File.read(output_path) do
        {:ok, png}
      else
        {:error, _reason} = error ->
          error

        {output, status} ->
          {:error,
           "comic compositor exited with status #{status}: #{String.trim(output)}"}
      end
    after
      File.rm(base_path)
      File.rm(foreground_path)
      File.rm(output_path)
    end
  end

  defp rasterize(svg) do
    token = System.unique_integer([:positive, :monotonic])
    svg_path = Path.join(System.tmp_dir!(), "froth-comic-#{token}.svg")
    png_path = Path.join(System.tmp_dir!(), "froth-comic-#{token}.png")

    try do
      with executable when is_binary(executable) <-
             System.find_executable("convert") ||
               {:error,
                "ImageMagick's convert executable is required to rasterize comics"},
           :ok <- File.write(svg_path, svg),
           {_output, 0} <-
             System.cmd(
               executable,
               ["-background", "none", svg_path, "-strip", png_path],
               stderr_to_stdout: true
             ),
           {:ok, png} <- File.read(png_path) do
        {:ok, png}
      else
        {:error, _reason} = error ->
          error

        {output, status} ->
          {:error,
           "comic rasterizer exited with status #{status}: #{String.trim(output)}"}
      end
    after
      File.rm(svg_path)
      File.rm(png_path)
    end
  end

  defp points(points),
    do: Enum.map_join(points, " ", fn {x, y} -> "#{x},#{y}" end)

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp default_asset_root,
    do: Application.app_dir(:froth, "priv/comic_chat")

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
