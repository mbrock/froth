defmodule Froth.MimeSniff do
  @moduledoc """
  Magic-byte content-type detection, `file(1)` style.

  Returns a concrete MIME string when a known signature is recognized
  at the head of the binary, otherwise `nil`. Callers are expected to
  fall back to `application/octet-stream` (or their own default) on a
  miss.

  The table covers the formats most likely to come out of a shell
  pipeline or a small file read: the common web image formats, a few
  container formats (MP4/MOV/WebM/OGG/MP3/WAV/FLAC), PDF, and the
  common archive formats (ZIP and variants, gzip, 7z, xz, bzip2, tar).

  This isn't exhaustive — it's meant to be the thing that answers
  "did the agent just print a PNG into the shell?" accurately and
  leaves everything else as `application/octet-stream` so downstream
  storage still works.
  """

  @doc """
  Sniff the MIME type of a binary from its leading bytes.

  Returns a MIME string on a match, `nil` otherwise. Always returns
  `nil` for non-binaries.
  """
  @spec sniff(binary() | any()) :: String.t() | nil
  def sniff(data) when is_binary(data), do: do_sniff(data)
  def sniff(_), do: nil

  # Images
  defp do_sniff(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp do_sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp do_sniff(<<"GIF87a", _::binary>>), do: "image/gif"
  defp do_sniff(<<"GIF89a", _::binary>>), do: "image/gif"
  defp do_sniff(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  defp do_sniff(<<"BM", _::binary>>), do: "image/bmp"
  defp do_sniff(<<0x49, 0x49, 0x2A, 0x00, _::binary>>), do: "image/tiff"
  defp do_sniff(<<0x4D, 0x4D, 0x00, 0x2A, _::binary>>), do: "image/tiff"

  # HEIC/HEIF and MP4/MOV share the ISO BMFF "ftyp" box at offset 4.
  # Dispatch by the brand that follows.
  defp do_sniff(<<_::32, "ftyp", brand::binary-size(4), _::binary>>) do
    case brand do
      "heic" -> "image/heic"
      "heix" -> "image/heic"
      "hevc" -> "image/heic"
      "hevx" -> "image/heic"
      "heim" -> "image/heic"
      "heis" -> "image/heic"
      "heif" -> "image/heif"
      "mif1" -> "image/heif"
      "msf1" -> "image/heif"
      "avif" -> "image/avif"
      "avis" -> "image/avif"
      "qt  " -> "video/quicktime"
      "M4V " -> "video/mp4"
      "M4A " -> "audio/mp4"
      "M4B " -> "audio/mp4"
      "M4P " -> "audio/mp4"
      _ -> "video/mp4"
    end
  end

  # Containers and media
  defp do_sniff(<<"OggS", _::binary>>), do: "audio/ogg"
  defp do_sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  defp do_sniff(<<"RIFF", _::32, "WAVE", _::binary>>), do: "audio/wav"
  defp do_sniff(<<"RIFF", _::32, "AVI ", _::binary>>), do: "video/x-msvideo"
  defp do_sniff(<<"fLaC", _::binary>>), do: "audio/flac"
  defp do_sniff(<<"ID3", _::binary>>), do: "audio/mpeg"

  defp do_sniff(<<0xFF, b, _::binary>>) when b in [0xFB, 0xF3, 0xF2],
    do: "audio/mpeg"

  # Documents
  defp do_sniff(<<"%PDF-", _::binary>>), do: "application/pdf"
  defp do_sniff(<<"{\\rtf", _::binary>>), do: "application/rtf"

  # Archives / compressed
  defp do_sniff(<<"PK", 0x03, 0x04, _::binary>>), do: "application/zip"
  defp do_sniff(<<"PK", 0x05, 0x06, _::binary>>), do: "application/zip"
  defp do_sniff(<<"PK", 0x07, 0x08, _::binary>>), do: "application/zip"
  defp do_sniff(<<0x1F, 0x8B, _::binary>>), do: "application/gzip"
  defp do_sniff(<<0x42, 0x5A, 0x68, _::binary>>), do: "application/x-bzip2"
  defp do_sniff(<<0xFD, "7zXZ", 0x00, _::binary>>), do: "application/x-xz"

  defp do_sniff(<<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, _::binary>>),
    do: "application/x-7z-compressed"

  defp do_sniff(<<"Rar!", 0x1A, 0x07, _::binary>>), do: "application/vnd.rar"
  defp do_sniff(<<"ustar", _::binary>>), do: "application/x-tar"

  # POSIX tar: "ustar" magic lives at offset 257 of the first 512-byte block.
  defp do_sniff(<<_::binary-size(257), "ustar", _::binary>>),
    do: "application/x-tar"

  # Executables / objects
  defp do_sniff(<<0x7F, "ELF", _::binary>>), do: "application/x-elf"

  defp do_sniff(<<"MZ", _::binary>>),
    do: "application/vnd.microsoft.portable-executable"

  defp do_sniff(<<0xCA, 0xFE, 0xBA, 0xBE, _::binary>>),
    do: "application/java-vm"

  defp do_sniff(<<0xFE, 0xED, 0xFA, 0xCE, _::binary>>),
    do: "application/x-mach-binary"

  defp do_sniff(<<0xFE, 0xED, 0xFA, 0xCF, _::binary>>),
    do: "application/x-mach-binary"

  defp do_sniff(<<0xCF, 0xFA, 0xED, 0xFE, _::binary>>),
    do: "application/x-mach-binary"

  # SQLite database
  defp do_sniff(<<"SQLite format 3", 0, _::binary>>),
    do: "application/vnd.sqlite3"

  defp do_sniff(_), do: nil
end
