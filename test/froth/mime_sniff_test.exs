defmodule Froth.MimeSniffTest do
  use ExUnit.Case, async: true

  alias Froth.MimeSniff

  describe "sniff/1 — images" do
    test "recognizes PNG" do
      assert MimeSniff.sniff(<<0x89, "PNG\r\n", 0x1A, 0x0A, 0, 0>>) ==
               "image/png"
    end

    test "recognizes JPEG" do
      assert MimeSniff.sniff(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10>>) ==
               "image/jpeg"
    end

    test "recognizes GIF87a and GIF89a" do
      assert MimeSniff.sniff("GIF87a" <> <<0, 0>>) == "image/gif"
      assert MimeSniff.sniff("GIF89a" <> <<0, 0>>) == "image/gif"
    end

    test "recognizes WebP" do
      data = "RIFF" <> <<100::32>> <> "WEBP" <> "VP8 "
      assert MimeSniff.sniff(data) == "image/webp"
    end

    test "recognizes BMP" do
      assert MimeSniff.sniff("BM" <> <<0, 0, 0, 0>>) == "image/bmp"
    end

    test "recognizes TIFF (little and big endian)" do
      assert MimeSniff.sniff(<<0x49, 0x49, 0x2A, 0x00, 0, 0>>) == "image/tiff"
      assert MimeSniff.sniff(<<0x4D, 0x4D, 0x00, 0x2A, 0, 0>>) == "image/tiff"
    end
  end

  describe "sniff/1 — ISO BMFF (ftyp box)" do
    test "recognizes HEIC" do
      data = <<0::32, "ftyp", "heic", 0::32>>
      assert MimeSniff.sniff(data) == "image/heic"
    end

    test "recognizes HEIF" do
      data = <<0::32, "ftyp", "mif1", 0::32>>
      assert MimeSniff.sniff(data) == "image/heif"
    end

    test "recognizes AVIF" do
      data = <<0::32, "ftyp", "avif", 0::32>>
      assert MimeSniff.sniff(data) == "image/avif"
    end

    test "recognizes QuickTime" do
      data = <<0::32, "ftyp", "qt  ", 0::32>>
      assert MimeSniff.sniff(data) == "video/quicktime"
    end

    test "unknown ftyp brand defaults to mp4" do
      data = <<0::32, "ftyp", "iso5", 0::32>>
      assert MimeSniff.sniff(data) == "video/mp4"
    end
  end

  describe "sniff/1 — audio/video containers" do
    test "recognizes OGG" do
      assert MimeSniff.sniff("OggS" <> <<0, 2>>) == "audio/ogg"
    end

    test "recognizes WebM/Matroska EBML header" do
      assert MimeSniff.sniff(<<0x1A, 0x45, 0xDF, 0xA3, 0, 0>>) == "video/webm"
    end

    test "recognizes WAV" do
      data = "RIFF" <> <<100::32>> <> "WAVE"
      assert MimeSniff.sniff(data) == "audio/wav"
    end

    test "recognizes FLAC" do
      assert MimeSniff.sniff("fLaC" <> <<0, 0>>) == "audio/flac"
    end

    test "recognizes MP3 via ID3 header" do
      assert MimeSniff.sniff("ID3" <> <<0, 0>>) == "audio/mpeg"
    end

    test "recognizes MP3 via MPEG frame sync" do
      assert MimeSniff.sniff(<<0xFF, 0xFB, 0, 0>>) == "audio/mpeg"
      assert MimeSniff.sniff(<<0xFF, 0xF3, 0, 0>>) == "audio/mpeg"
      assert MimeSniff.sniff(<<0xFF, 0xF2, 0, 0>>) == "audio/mpeg"
    end
  end

  describe "sniff/1 — documents and archives" do
    test "recognizes PDF" do
      assert MimeSniff.sniff("%PDF-1.7\n") == "application/pdf"
    end

    test "recognizes ZIP" do
      assert MimeSniff.sniff(<<"PK", 0x03, 0x04, 0, 0>>) == "application/zip"
    end

    test "recognizes gzip" do
      assert MimeSniff.sniff(<<0x1F, 0x8B, 0x08>>) == "application/gzip"
    end

    test "recognizes 7z" do
      assert MimeSniff.sniff(<<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C>>) ==
               "application/x-7z-compressed"
    end

    test "recognizes xz" do
      assert MimeSniff.sniff(<<0xFD, "7zXZ", 0x00>>) == "application/x-xz"
    end

    test "recognizes bzip2" do
      assert MimeSniff.sniff(<<0x42, 0x5A, 0x68>>) == "application/x-bzip2"
    end

    test "recognizes tar (ustar at offset 257)" do
      prefix = :binary.copy(<<0>>, 257)
      data = prefix <> "ustar" <> :binary.copy(<<0>>, 100)
      assert MimeSniff.sniff(data) == "application/x-tar"
    end
  end

  describe "sniff/1 — binaries without a known signature" do
    test "returns nil for plain text" do
      assert MimeSniff.sniff("hello world") == nil
    end

    test "returns nil for random bytes" do
      # Keep it short so we don't accidentally hit the tar offset.
      assert MimeSniff.sniff(<<0xAB, 0xCD, 0xEF, 0x01, 0x02>>) == nil
    end

    test "returns nil for empty binary" do
      assert MimeSniff.sniff("") == nil
    end

    test "returns nil for non-binary input" do
      assert MimeSniff.sniff(nil) == nil
      assert MimeSniff.sniff(42) == nil
      assert MimeSniff.sniff([]) == nil
    end
  end
end
