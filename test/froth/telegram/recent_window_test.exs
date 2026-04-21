defmodule Froth.Telegram.RecentWindowTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.RecentWindow

  test "backfills beyond the target window while under budget" do
    range_end = 10 * 3600

    rows =
      0..9
      |> Enum.map(fn bucket ->
        row(
          bucket * 1800 + 60,
          bucket + 1,
          String.duplicate("a", 20)
        )
      end)

    selected =
      RecentWindow.select_rows(rows, range_end, %{
        target_hours: 4,
        min_hours: 1,
        backfill_hours: 8,
        char_budget: 10_000,
        bucket_minutes: 30
      })

    assert Enum.map(selected, & &1.message_id) ==
             Enum.map(rows, & &1.message_id)
  end

  test "trims oldest buckets to stay within budget but keeps the minimum horizon" do
    range_end = 8 * 3600

    rows =
      0..7
      |> Enum.map(fn bucket ->
        row(
          bucket * 1800 + 60,
          bucket + 1,
          String.duplicate("a", 100)
        )
      end)

    selected =
      RecentWindow.select_rows(rows, range_end, %{
        target_hours: 4,
        min_hours: 1,
        backfill_hours: 8,
        char_budget: 250,
        bucket_minutes: 30
      })

    assert Enum.map(selected, & &1.message_id) == [7, 8]
  end

  test "adding a message inside the newest bucket does not move the oldest retained bucket" do
    range_end = 6 * 3600

    base_rows =
      0..5
      |> Enum.map(fn bucket ->
        row(
          bucket * 1800 + 60,
          bucket + 1,
          String.duplicate("a", 80)
        )
      end)

    extra_row = row(5 * 1800 + 300, 99, "extra")

    config = %{
      target_hours: 2,
      min_hours: 1,
      backfill_hours: 6,
      char_budget: 10_000,
      bucket_minutes: 30
    }

    base_selected = RecentWindow.select_rows(base_rows, range_end, config)

    with_extra_selected =
      RecentWindow.select_rows(base_rows ++ [extra_row], range_end, config)

    assert hd(base_selected).message_id == hd(with_extra_selected).message_id
  end

  defp row(date, message_id, text) do
    %{
      date: date,
      sender_id: 1,
      message_id: message_id,
      inserted_at: nil,
      raw: %{
        "content" => %{
          "@type" => "messageText",
          "text" => %{"text" => text}
        }
      }
    }
  end
end
