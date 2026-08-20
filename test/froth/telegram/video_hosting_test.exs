defmodule Froth.Telegram.VideoHostingTest do
  use ExUnit.Case, async: false

  alias Froth.Analyzer.Discovery
  alias Froth.Telegram.VideoHosting

  setup do
    previous = Application.get_env(:froth, VideoHosting, [])
    Application.put_env(:froth, VideoHosting, threshold_bytes: 100)

    on_exit(fn -> Application.put_env(:froth, VideoHosting, previous) end)
  end

  test "large Telegram videos get a separate hosting job" do
    message = video_message(100)

    assert [
             {"video", Froth.Analyzer.VideoWorker, %{}},
             {"video_host", Froth.Telegram.VideoHostingWorker, %{}}
           ] = Discovery.classify(message)

    assert [{"video", Froth.Analyzer.VideoWorker, %{}}] =
             Discovery.classify(video_message(99))
  end

  test "large MP4 documents get hosted like Telegram's file-shaped videos" do
    message = %{
      "chat_id" => -1001,
      "id" => 43,
      "content" => %{
        "@type" => "messageDocument",
        "document" => %{
          "file_name" => "large.mp4",
          "mime_type" => "video/mp4",
          "document" => %{"id" => 8, "expected_size" => 101}
        }
      }
    }

    assert [{"video_host", Froth.Telegram.VideoHostingWorker, %{}}] =
             Discovery.classify(message)
  end

  test "bot selection is deterministic and only considers chat members" do
    configs = [
      %{session_id: "charlie"},
      %{session_id: "luna"},
      %{session_id: "terrie"}
    ]

    lookup = fn config, -1001 ->
      config.session_id in ["charlie", "terrie"]
    end

    assert {:ok, selected} =
             VideoHosting.choose_session(-1001, configs, lookup)

    assert selected in ["charlie", "terrie"]

    assert {:ok, ^selected} =
             VideoHosting.choose_session(-1001, Enum.reverse(configs), lookup)
  end

  test "bot selection reports when no configured identity is in the chat" do
    assert {:error, :no_bot_in_chat} =
             VideoHosting.choose_session(
               -1001,
               [%{session_id: "terrie"}],
               fn _, _ -> false end
             )
  end

  defp video_message(size) do
    %{
      "chat_id" => -1001,
      "id" => 42,
      "content" => %{
        "@type" => "messageVideo",
        "video" => %{
          "mime_type" => "video/mp4",
          "video" => %{"id" => 7, "expected_size" => size}
        }
      }
    }
  end
end
