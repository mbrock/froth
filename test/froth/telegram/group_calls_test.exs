defmodule Froth.Telegram.GroupCallsTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.GroupCalls

  test "group_call_join_parameters uses sane defaults" do
    assert GroupCalls.group_call_join_parameters(1234, "{\"x\":1}") == %{
             "@type" => "groupCallJoinParameters",
             "audio_source_id" => 1234,
             "payload" => "{\"x\":1}",
             "is_muted" => true,
             "is_my_video_enabled" => false
           }
  end

  test "group_call_join_parameters accepts overrides" do
    assert GroupCalls.group_call_join_parameters(44, "{}",
             is_muted: false,
             is_my_video_enabled: true
           ) ==
             %{
               "@type" => "groupCallJoinParameters",
               "audio_source_id" => 44,
               "payload" => "{}",
               "is_muted" => false,
               "is_my_video_enabled" => true
             }
  end

  test "join_video_chat_request builds expected payload" do
    participant = %{"@type" => "messageSenderUser", "user_id" => 7}

    assert GroupCalls.join_video_chat_request(55, 999, "{\"join\":true}",
             participant_id: participant,
             invite_hash: "abc",
             is_muted: false
           ) == %{
             "@type" => "joinVideoChat",
             "group_call_id" => 55,
             "participant_id" => participant,
             "invite_hash" => "abc",
             "join_parameters" => %{
               "@type" => "groupCallJoinParameters",
               "audio_source_id" => 999,
               "payload" => "{\"join\":true}",
               "is_muted" => false,
               "is_my_video_enabled" => false
             }
           }
  end
end
