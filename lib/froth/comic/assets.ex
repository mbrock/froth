defmodule Froth.Comic.Assets do
  @moduledoc """
  Linux-friendly extraction of simple Comic Chat `.avb` avatars.

  AVB files are little-endian record containers whose art records point to
  embedded BMP streams. This parser intentionally supports the simple avatar
  type used by the Jim Woodring-style characters bundled with Comic Chat.
  """

  @magic 0x81
  @simple 1

  @spec parse(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse(
        <<@magic::little-16, @simple::little-16, version::little-16,
          rest::binary>>
      ) do
    parse_records(rest, %{version: version, type: :simple, bodies: []})
  end

  def parse(<<@magic::little-16, type::little-16, _::binary>>),
    do:
      {:error,
       "unsupported AVB avatar type #{type}; only simple avatars can be extracted"}

  def parse(_binary), do: {:error, "invalid AVB header"}

  @spec extract_avatar(Path.t(), Path.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def extract_avatar(source_path, output_dir) do
    with {:ok, binary} <- File.read(source_path),
         {:ok, avatar} <- parse(binary),
         :ok <- File.mkdir_p(output_dir) do
      avatar.bodies
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {body, index}, {:ok, paths} ->
        path = Path.join(output_dir, "pose-#{index}.png")

        with {:ok, bmp} <- embedded_bmp(binary, body.foreground_offset),
             :ok <- convert_embedded_bmp(bmp, path) do
          {:cont, {:ok, [path | paths]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        error -> error
      end
    end
  end

  @spec convert_bitmap(Path.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def convert_bitmap(source_path, output_path) do
    with :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- run_convert([source_path, output_path]) do
      {:ok, output_path}
    end
  end

  defp convert_embedded_bmp(bmp, output_path) do
    temporary =
      Path.join(
        System.tmp_dir!(),
        "froth-comic-#{System.unique_integer([:positive, :monotonic])}.bmp"
      )

    try do
      with :ok <- File.write(temporary, bmp) do
        run_convert([temporary, "-transparent", "white", output_path])
      end
    after
      File.rm(temporary)
    end
  end

  defp run_convert(args) do
    case System.find_executable("convert") do
      nil ->
        {:error,
         "ImageMagick's convert executable is required to extract Comic Chat BMP assets"}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            {:error,
             "convert exited with status #{status}: #{String.trim(output)}"}
        end
    end
  end

  defp parse_records(<<1::little-16, rest::binary>>, avatar) do
    case :binary.match(rest, <<0>>) do
      {length, 1} ->
        <<name::binary-size(length), 0, tail::binary>> = rest
        parse_records(tail, Map.put(avatar, :name, name))

      :nomatch ->
        {:error, "unterminated AVB avatar name"}
    end
  end

  defp parse_records(
         <<key::little-16, value::little-16, rest::binary>>,
         avatar
       )
       when key in [2, 8],
       do:
         parse_records(
           rest,
           Map.put(avatar, if(key == 2, do: :flags, else: :style), value)
         )

  defp parse_records(
         <<3::little-16, offset::little-32, rest::binary>>,
         avatar
       ),
       do: parse_records(rest, Map.put(avatar, :icon_offset, offset))

  defp parse_records(<<9::little-16, count::little-16, rest::binary>>, avatar) do
    with {:ok, bodies, tail} <- parse_bodies(rest, count, []) do
      parse_records(tail, Map.put(avatar, :bodies, bodies))
    end
  end

  defp parse_records(<<6::little-16, _rest::binary>>, avatar),
    do: {:ok, avatar}

  defp parse_records(<<key::little-16, _::binary>>, _avatar),
    do: {:error, "unexpected AVB record key #{key}"}

  defp parse_records(_binary, _avatar), do: {:error, "truncated AVB metadata"}

  defp parse_bodies(rest, 0, bodies), do: {:ok, Enum.reverse(bodies), rest}

  defp parse_bodies(
         <<foreground::little-32, transparency::little-32, aura::little-32,
           emotion::little-16, intensity::8, face_x::little-16,
           face_y::little-16, _padding::binary-size(16), rest::binary>>,
         count,
         bodies
       ) do
    body = %{
      foreground_offset: foreground,
      transparency_offset: transparency,
      aura_offset: aura,
      emotion_index: emotion,
      intensity: intensity / 255,
      face_x: face_x,
      face_y: face_y
    }

    parse_bodies(rest, count - 1, [body | bodies])
  end

  defp parse_bodies(_binary, _count, _bodies),
    do: {:error, "truncated AVB body table"}

  defp embedded_bmp(binary, offset)
       when offset >= 0 and offset + 6 <= byte_size(binary) do
    case binary_part(binary, offset, byte_size(binary) - offset) do
      <<"BM", size::little-32, _::binary>>
      when size >= 14 and offset + size <= byte_size(binary) ->
        {:ok, binary_part(binary, offset, size)}

      _ ->
        {:error, "AVB art offset #{offset} does not point to a complete BMP"}
    end
  end

  defp embedded_bmp(_binary, offset),
    do: {:error, "invalid AVB art offset #{offset}"}
end
