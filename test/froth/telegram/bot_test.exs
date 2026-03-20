defmodule Froth.Telegram.BotTest do
  use ExUnit.Case, async: true

  test "struct includes mid-cycle message buffer" do
    assert %Froth.Telegram.Bot{mid_cycle_messages: []} = %Froth.Telegram.Bot{}
  end
end
