defmodule Froth.Telegram.BackfillTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Backfill

  @chat_id -1_003_690_254_489
  @fixture_dir Path.expand("../../fixtures/telegram_backfill", __DIR__)

  test "translates a real Telethon message and its entities" do
    source =
      fixture!(
        "20260915T000012,000Z.cid=-1003690254489.mid=166284.uid=8879880403.backfill.tg.json"
      )

    assert {:ok, raw} = Backfill.translate(source, @chat_id)
    assert raw["@type"] == "message"
    assert raw["id"] == 166_284 * 1_048_576
    assert raw["date"] == 1_789_430_412

    assert raw["sender_id"] == %{
             "@type" => "messageSenderUser",
             "user_id" => 8_879_880_403
           }

    assert raw["content"]["@type"] == "messageText"

    assert [first | _] = raw["content"]["text"]["entities"]
    assert first["type"] == %{"@type" => "textEntityTypeMention"}
    assert first["offset"] == 296
    assert raw["froth_backfill"]["media_recovery_required"] == false
  end

  test "translates a real reply header using TDLib message ids" do
    source =
      fixture!(
        "20260915T000013,000Z.cid=-1003690254489.mid=166285.uid=8044965953.backfill.tg.json"
      )

    assert {:ok, raw} = Backfill.translate(source, @chat_id)

    assert raw["reply_to"] == %{
             "@type" => "messageReplyToMessage",
             "chat_id" => @chat_id,
             "message_id" => 166_281 * 1_048_576,
             "origin_send_date" => 0
           }
  end

  test "media uses native content types without fabricated TDLib file ids" do
    source = %{
      "_" => "Message",
      "id" => 42,
      "date" => "2026-09-15 00:00:13+00:00",
      "message" => "voice caption",
      "from_id" => %{"_" => "PeerUser", "user_id" => 7},
      "entities" => [],
      "media" => %{
        "_" => "MessageMediaDocument",
        "voice" => true,
        "document" => %{"attributes" => []}
      }
    }

    assert {:ok, raw} = Backfill.translate(source, @chat_id)
    assert raw["content"]["@type"] == "messageVoiceNote"
    assert raw["content"]["caption"]["text"] == "voice caption"
    refute Map.has_key?(raw["content"], "voice_note")
    assert raw["froth_backfill"]["media_recovery_required"]
  end

  defp fixture!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
