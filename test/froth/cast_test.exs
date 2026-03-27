defmodule Froth.CastTest do
  use ExUnit.Case, async: true

  alias Froth.Cast
  alias Froth.Cast.Recording

  test "parse_file/1 supports asciicast v1" do
    assert {:ok, %Recording{} = recording} = Cast.parse_file(fixture("simple_v1.cast"))

    assert recording.version == 1
    assert recording.cols == 80
    assert recording.rows == 24
    assert recording.title == "Simple v1"
    assert recording.terminal_type == "xterm-256color"
    assert recording.duration_s == 1.75
    assert Enum.map(recording.events, &Float.round(&1.at, 2)) == [0.1, 0.75]
    assert Enum.map(recording.events, & &1.code) == ["o", "o"]
  end

  test "parse_file/1 supports asciicast v2 with themes and resizes" do
    assert {:ok, %Recording{} = recording} = Cast.parse_file(fixture("simple_v2.cast"))

    assert recording.version == 2
    assert recording.cols == 80
    assert recording.rows == 24
    assert recording.max_cols == 100
    assert recording.max_rows == 30
    assert recording.idle_time_limit == 0.75
    assert recording.theme.name == "custom"
    assert Float.round(List.last(recording.events).at, 2) == 2.25
  end

  test "parse_file/1 supports asciicast v3 relative timing and comments" do
    assert {:ok, %Recording{} = recording} = Cast.parse_file(fixture("simple_v3.cast"))

    assert recording.version == 3
    assert recording.cols == 82
    assert recording.rows == 25
    assert recording.max_cols == 90
    assert recording.max_rows == 28
    assert recording.theme.bg == "#282a36"
    assert Enum.map(recording.events, &Float.round(&1.at, 2)) == [0.1, 0.25, 0.5, 0.55]
    assert Enum.map(recording.events, & &1.code) == ["o", "o", "r", "x"]
  end

  test "prepare_recording/2 normalizes timing and builds interactive HTML" do
    assert {:ok, recording} = Cast.parse_file(fixture("simple_v2.cast"))

    assert {:ok, prepared} =
             Cast.prepare_recording(recording,
               speed: 2.0,
               idle_time_limit: 0.2,
               lead_out_s: 0.5,
               theme: "dracula",
               title: "Demo"
             )

    assert Enum.map(prepared.recording.events, &Float.round(&1.at, 2)) == [
             0.0,
             0.1,
             0.2,
             0.3,
             0.4
           ]

    assert Float.round(prepared.duration_s, 2) == 1.0
    assert rem(prepared.width, 2) == 0
    assert rem(prepared.height, 2) == 0
    assert prepared.recording.theme.name == "dracula"
    assert prepared.html =~ "window.FrothVideo"
    assert prepared.html =~ ~s(id="controls")
    assert prepared.html =~ ~s(id="play-button")
    assert prepared.html =~ "Demo"
  end

  test "write_html/2 writes a standalone player document" do
    output_path =
      Path.join(System.tmp_dir!(), "froth-cast-#{System.unique_integer([:positive])}.html")

    try do
      assert {:ok, result} =
               Cast.write_html(fixture("simple_v1.cast"),
                 output_path: output_path,
                 title: "Standalone Demo"
               )

      assert result.output_path == output_path
      assert File.exists?(output_path)

      html = File.read!(output_path)
      assert html =~ "Standalone Demo"
      assert html =~ "togglePlayback"
      assert html =~ "timeline-progress"
    after
      File.rm(output_path)
    end
  end

  defp fixture(name) do
    Path.expand("../fixtures/cast/#{name}", __DIR__)
  end
end
