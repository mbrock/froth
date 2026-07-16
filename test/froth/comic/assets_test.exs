defmodule Froth.Comic.AssetsTest do
  use ExUnit.Case, async: true

  alias Froth.Comic.Assets

  test "parses a simple AVB metadata table" do
    body =
      <<100::little-32, 200::little-32, 300::little-32, 9::little-16, 128::8,
        12::little-16, 34::little-16, 0::size(16 * 8)>>

    avb =
      <<0x81::little-16, 1::little-16, 1::little-16, 1::little-16, "Waf", 0,
        8::little-16, 1::little-16, 2::little-16, 5::little-16, 3::little-16,
        64::little-32, 9::little-16, 1::little-16, body::binary,
        6::little-16>>

    assert {:ok, avatar} = Assets.parse(avb)
    assert avatar.name == "Waf"
    assert avatar.icon_offset == 64
    assert avatar.flags == 5
    assert avatar.style == 1

    assert [
             %{
               foreground_offset: 100,
               transparency_offset: 200,
               aura_offset: 300,
               emotion_index: 9,
               face_x: 12,
               face_y: 34
             }
           ] = avatar.bodies
  end

  test "rejects complex and invalid containers" do
    assert {:error, error} =
             Assets.parse(<<0x81::little-16, 2::little-16, 1::little-16>>)

    assert error =~ "unsupported AVB avatar type"
    assert {:error, "invalid AVB header"} = Assets.parse("not an avatar")
  end
end
