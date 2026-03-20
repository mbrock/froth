defmodule Froth.VideoTest do
  use ExUnit.Case, async: true

  test "compose/4 returns self-contained HTML with the renderer API" do
    html =
      Froth.Video.compose(
        [
          %{word: "hello", start: 0.0, end: 0.5},
          %{word: "world", start: 0.5, end: 1.0}
        ],
        [
          %{src: "https://example.test/scene-1.jpg"},
          %{src: "https://example.test/scene-2.jpg"}
        ],
        "https://example.test/audio.mp3",
        title: "Spec Test",
        duration_s: 1.0
      )

    assert html =~ "<!doctype html>"
    assert html =~ "window.FrothVideo"
    assert html =~ "renderAt"
    assert html =~ "https://example.test/audio.mp3"
    assert html =~ "https://example.test/scene-1.jpg"
    assert html =~ "\"duration_s\":1.0"
  end

  test "record/2 returns an error when no audio input is supplied" do
    assert {:error, :missing_audio_input} =
             Froth.Video.record("<html><body>no audio</body></html>", duration_s: 1.0)
  end
end
