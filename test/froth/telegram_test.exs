defmodule Froth.TelegramTest do
  use Froth.TelegramBotCase, async: true

  test "send_image materializes a local path and returns fetch-style metadata" do
    chat_id = System.unique_integer([:positive])
    reply_to = System.unique_integer([:positive])
    session_id = start_fake_session()
    source_path = sample_png_path("local")

    assert {:ok, metadata} =
             Froth.Telegram.send_image(session_id, chat_id, source_path,
               caption: "caption",
               reply_to: reply_to
             )

    on_exit(fn ->
      File.rm(source_path)
      File.rm(metadata["local_path"])
    end)

    assert metadata["filename"] == Path.basename(source_path)
    assert metadata["media_type"] == "image/png"
    assert metadata["size_bytes"] > 0
    assert metadata["local_path"] =~ "/priv/static/files/"

    assert String.ends_with?(
             metadata["public_url"],
             Path.basename(metadata["local_path"])
           )

    assert File.read!(metadata["local_path"]) == File.read!(source_path)

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "reply_to" => %{
                        "@type" => "inputMessageReplyToMessage",
                        "message_id" => ^reply_to
                      },
                      "input_message_content" => %{
                        "@type" => "inputMessagePhoto",
                        "caption" => %{
                          "text" => caption_text,
                          "entities" => [link_entity]
                        },
                        "photo" => %{
                          "@type" => "inputFileLocal",
                          "path" => sent_path
                        }
                      }
                    }}

    assert sent_path == metadata["local_path"]
    assert caption_text == "caption · ↗"
    assert get_in(link_entity, ["type", "url"]) == metadata["public_url"]
  end

  test "send_image accepts an Nx tensor" do
    chat_id = System.unique_integer([:positive])
    session_id = start_fake_session()

    assert {:ok, metadata} =
             Froth.Telegram.send_image(session_id, chat_id, sample_tensor())

    on_exit(fn -> File.rm(metadata["local_path"]) end)

    assert String.ends_with?(metadata["filename"], ".png")
    assert metadata["media_type"] == "image/png"
    assert metadata["size_bytes"] > 0
    assert File.exists?(metadata["local_path"])

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "@type" => "inputMessagePhoto",
                        "photo" => %{"path" => sent_path}
                      }
                    }}

    assert sent_path == metadata["local_path"]
  end

  test "send_image accepts a Vix image value" do
    chat_id = System.unique_integer([:positive])
    session_id = start_fake_session()
    {:ok, image} = Image.from_nx(sample_tensor())

    assert {:ok, metadata} =
             Froth.Telegram.send_image(session_id, chat_id, image)

    on_exit(fn -> File.rm(metadata["local_path"]) end)

    assert String.ends_with?(metadata["filename"], ".png")
    assert metadata["media_type"] == "image/png"
    assert metadata["size_bytes"] > 0
    assert File.exists?(metadata["local_path"])

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "@type" => "inputMessagePhoto",
                        "photo" => %{"path" => sent_path}
                      }
                    }}

    assert sent_path == metadata["local_path"]
  end

  test "send_image sends albums and only captions the first image" do
    chat_id = System.unique_integer([:positive])
    session_id = start_fake_session()

    assert {:ok, [first_metadata, second_metadata]} =
             Froth.Telegram.send_image(
               session_id,
               chat_id,
               [sample_tensor(), sample_tensor()], caption: "album caption")

    on_exit(fn ->
      File.rm(first_metadata["local_path"])
      File.rm(second_metadata["local_path"])
    end)

    assert first_metadata["media_type"] == "image/png"
    assert second_metadata["media_type"] == "image/png"

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessageAlbum",
                      "chat_id" => ^chat_id,
                      "input_message_contents" => [
                        first_content,
                        second_content
                      ]
                    }}

    assert get_in(first_content, ["caption", "text"]) ==
             "album caption · 1 · 2"

    assert Enum.map(
             get_in(first_content, ["caption", "entities"]),
             &get_in(&1, ["type", "url"])
           ) ==
             [
               first_metadata["public_url"],
               second_metadata["public_url"]
             ]

    refute Map.has_key?(second_content, "caption")

    assert get_in(first_content, ["photo", "path"]) ==
             first_metadata["local_path"]

    assert get_in(second_content, ["photo", "path"]) ==
             second_metadata["local_path"]
  end

  test "send_photo still returns the raw Telegram response" do
    chat_id = System.unique_integer([:positive])
    session_id = start_fake_session()
    source_path = sample_png_path("photo")

    assert {:ok, %{"id" => _temp_id, "chat_id" => ^chat_id}} =
             Froth.Telegram.send_photo(session_id, chat_id, source_path,
               caption: "caption"
             )

    assert_receive {:telegram_call,
                    %{
                      "@type" => "sendMessage",
                      "chat_id" => ^chat_id,
                      "input_message_content" => %{
                        "@type" => "inputMessagePhoto",
                        "caption" => %{"text" => "caption"},
                        "photo" => %{"path" => durable_path}
                      }
                    }}

    on_exit(fn ->
      File.rm(source_path)
      File.rm(durable_path)
    end)

    assert durable_path =~ "/priv/static/files/"
  end

  defp sample_png_path(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "froth-telegram-#{label}-#{System.unique_integer([:positive])}.png"
      )

    {:ok, image} = Image.from_nx(sample_tensor())
    {:ok, _image} = Image.write(image, path)
    path
  end

  defp sample_tensor do
    Nx.tensor(
      [
        [[255, 0, 0], [0, 255, 0]],
        [[0, 0, 255], [255, 255, 0]]
      ],
      type: :u8
    )
  end
end
