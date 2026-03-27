defmodule Froth.Cast.Theme do
  @moduledoc false

  @default_palette [
    "#151515",
    "#ac4142",
    "#7e8e50",
    "#e5b567",
    "#6c99bb",
    "#9f4e85",
    "#7dd6cf",
    "#d0d0d0",
    "#505050",
    "#ac4142",
    "#7e8e50",
    "#e5b567",
    "#6c99bb",
    "#9f4e85",
    "#7dd6cf",
    "#f5f5f5"
  ]

  @presets %{
    "asciinema" => %{
      name: "asciinema",
      fg: "#d0d0d0",
      bg: "#121314",
      palette: @default_palette
    },
    "dracula" => %{
      name: "dracula",
      fg: "#f8f8f2",
      bg: "#282a36",
      palette: [
        "#21222c",
        "#ff5555",
        "#50fa7b",
        "#f1fa8c",
        "#bd93f9",
        "#ff79c6",
        "#8be9fd",
        "#f8f8f2",
        "#6272a4",
        "#ff6e6e",
        "#69ff94",
        "#ffffa5",
        "#d6acff",
        "#ff92df",
        "#a4ffff",
        "#ffffff"
      ]
    },
    "nord" => %{
      name: "nord",
      fg: "#d8dee9",
      bg: "#2e3440",
      palette: [
        "#3b4252",
        "#bf616a",
        "#a3be8c",
        "#ebcb8b",
        "#81a1c1",
        "#b48ead",
        "#88c0d0",
        "#e5e9f0",
        "#4c566a",
        "#bf616a",
        "#a3be8c",
        "#ebcb8b",
        "#81a1c1",
        "#b48ead",
        "#8fbcbb",
        "#eceff4"
      ]
    },
    "solarized-dark" => %{
      name: "solarized-dark",
      fg: "#839496",
      bg: "#002b36",
      palette: [
        "#073642",
        "#dc322f",
        "#859900",
        "#b58900",
        "#268bd2",
        "#d33682",
        "#2aa198",
        "#eee8d5",
        "#002b36",
        "#cb4b16",
        "#586e75",
        "#657b83",
        "#839496",
        "#6c71c4",
        "#93a1a1",
        "#fdf6e3"
      ]
    },
    "solarized-light" => %{
      name: "solarized-light",
      fg: "#657b83",
      bg: "#fdf6e3",
      palette: [
        "#073642",
        "#dc322f",
        "#859900",
        "#b58900",
        "#268bd2",
        "#d33682",
        "#2aa198",
        "#eee8d5",
        "#002b36",
        "#cb4b16",
        "#586e75",
        "#657b83",
        "#839496",
        "#6c71c4",
        "#93a1a1",
        "#fdf6e3"
      ]
    }
  }

  def default, do: Map.fetch!(@presets, "asciinema")

  def preset_names do
    @presets
    |> Map.keys()
    |> Enum.sort()
  end

  def resolve(theme, override \\ nil)

  def resolve(theme, nil) do
    case normalize(theme) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:ok, default()}
    end
  end

  def resolve(theme, "auto"), do: resolve(theme, nil)

  def resolve(_theme, override) when is_binary(override) do
    case Map.get(@presets, String.downcase(String.trim(override))) do
      nil -> {:error, {:unknown_theme, override}}
      preset -> {:ok, preset}
    end
  end

  def resolve(_theme, override) when is_map(override) do
    case normalize(override) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_theme, override}}
    end
  end

  def resolve(theme, _override), do: resolve(theme, nil)

  def normalize(theme) when is_map(theme) do
    fg = Map.get(theme, :fg) || Map.get(theme, "fg")
    bg = Map.get(theme, :bg) || Map.get(theme, "bg")
    palette = Map.get(theme, :palette) || Map.get(theme, "palette")
    name = Map.get(theme, :name) || Map.get(theme, "name")

    with true <- is_binary(fg) and fg != "",
         true <- is_binary(bg) and bg != "",
         {:ok, palette} <- normalize_palette(palette) do
      {:ok, %{name: name || "custom", fg: fg, bg: bg, palette: palette}}
    else
      _ -> :error
    end
  end

  def normalize(_theme), do: :error

  defp normalize_palette(palette) when is_binary(palette) do
    palette
    |> String.split(":", trim: true)
    |> normalize_palette()
  end

  defp normalize_palette(palette) when is_list(palette) do
    palette =
      palette
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    cond do
      length(palette) >= 16 ->
        {:ok, Enum.take(palette, 16)}

      length(palette) == 8 ->
        {:ok, palette ++ palette}

      true ->
        :error
    end
  end

  defp normalize_palette(_palette), do: :error
end
