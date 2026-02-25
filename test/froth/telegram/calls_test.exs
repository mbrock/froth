defmodule Froth.Telegram.CallsTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.Calls

  test "call_protocol uses explicit overrides" do
    protocol =
      Calls.call_protocol(
        library_versions: ["13.0.0"],
        max_layer: 92,
        min_layer: 65,
        udp_p2p: true,
        udp_reflector: true
      )

    assert protocol == %{
             "@type" => "callProtocol",
             "udp_p2p" => true,
             "udp_reflector" => true,
             "min_layer" => 65,
             "max_layer" => 92,
             "library_versions" => ["13.0.0"]
           }
  end

  test "call_protocol falls back to known versions when none available" do
    protocol = Calls.call_protocol(status_timeout: 1)

    assert protocol["@type"] == "callProtocol"
    assert is_integer(protocol["max_layer"])
    assert protocol["max_layer"] > 0
    assert is_list(protocol["library_versions"])
    assert protocol["library_versions"] != []
  end

  test "create_call_request includes optional is_video" do
    protocol = %{"@type" => "callProtocol"}

    assert Calls.create_call_request(123, protocol, is_video: true) == %{
             "@type" => "createCall",
             "user_id" => 123,
             "protocol" => protocol,
             "is_video" => true
           }
  end

  test "accept_call_request builds expected payload" do
    protocol = %{"@type" => "callProtocol"}

    assert Calls.accept_call_request(44, protocol) == %{
             "@type" => "acceptCall",
             "call_id" => 44,
             "protocol" => protocol
           }
  end

  test "send_call_signaling_data_request base64 encodes binaries by default" do
    request = Calls.send_call_signaling_data_request(7, <<1, 2, 3>>)

    assert request == %{
             "@type" => "sendCallSignalingData",
             "call_id" => 7,
             "data" => Base.encode64(<<1, 2, 3>>)
           }
  end

  test "send_call_signaling_data_request accepts pre-encoded data" do
    request = Calls.send_call_signaling_data_request(7, "AQID", data_is_base64: true)

    assert request == %{
             "@type" => "sendCallSignalingData",
             "call_id" => 7,
             "data" => "AQID"
           }
  end

  test "discard_call_request uses sane defaults" do
    assert Calls.discard_call_request(55) == %{
             "@type" => "discardCall",
             "call_id" => 55,
             "is_disconnected" => true,
             "duration" => 0,
             "connection_id" => 0
           }
  end

  test "route_tgcalls_update ignores unrelated updates" do
    assert Calls.route_tgcalls_update("session", %{"@type" => "updateNewMessage"}) == :ignore
  end

  test "start_tgcalls_call rejects non-ready call updates before cnode interaction" do
    assert Calls.start_tgcalls_call("session", %{"id" => 7}) == {:error, :call_not_ready}
  end
end
