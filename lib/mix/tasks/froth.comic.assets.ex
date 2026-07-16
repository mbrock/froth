defmodule Mix.Tasks.Froth.Comic.Assets do
  @moduledoc """
  Extract Comic Chat's Woodring-style avatars, backdrops, and font.

      mix froth.comic.assets /tmp/comic-chat

  The task reads the v1.0 checkout and writes runtime assets under
  `priv/comic_chat`. The source repository's MIT license is copied alongside
  the derived assets.
  """
  @shortdoc "Extract Comic Chat assets for Froth"

  use Mix.Task

  alias Froth.Comic.Assets

  @avatars ~w(waf glenda pedagog rainbow tux)

  @impl Mix.Task
  def run(args) do
    root = List.first(args) || "/tmp/comic-chat"
    source = Path.join(root, "v1.0")
    target = Application.app_dir(:froth, "priv/comic_chat")

    unless File.dir?(source),
      do: Mix.raise("Comic Chat v1.0 not found under #{root}")

    File.mkdir_p!(Path.join(target, "fonts"))

    File.cp!(
      Path.join(source, "shared/comic.ttf"),
      Path.join(target, "fonts/comic.ttf")
    )

    File.cp!(
      Path.join(root, "LICENSE"),
      Path.join(target, "LICENSE.microsoft-comic-chat")
    )

    Enum.each(@avatars, fn name ->
      avb = Path.join([source, "client/comicart/avatars", name <> ".avb"])

      output =
        Path.join(
          System.tmp_dir!(),
          "froth-comic-#{name}-#{System.unique_integer([:positive, :monotonic])}"
        )

      try do
        case Assets.extract_avatar(avb, output) do
          {:ok, [first | _]} ->
            destination = Path.join([target, "avatars", name <> ".png"])
            File.mkdir_p!(Path.dirname(destination))
            File.cp!(first, destination)
            Mix.shell().info("extracted #{name} -> #{destination}")

          {:ok, []} ->
            Mix.raise("#{avb} contains no body art")

          {:error, reason} ->
            Mix.raise("could not extract #{avb}: #{inspect(reason)}")
        end
      after
        File.rm_rf(output)
      end
    end)

    Enum.each(~w(field pastoral room8bs), fn name ->
      input = Path.join([source, "client/comicart/backdrop", name <> ".bmp"])
      output = Path.join([target, "backdrops", name <> ".png"])

      case Assets.convert_bitmap(input, output) do
        {:ok, _path} ->
          Mix.shell().info("converted #{name} -> #{output}")

        {:error, reason} ->
          Mix.raise("could not convert #{input}: #{inspect(reason)}")
      end
    end)
  end
end
