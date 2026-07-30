defmodule Froth.NarrativeContextTest do
  use ExUnit.Case, async: true

  alias Froth.{ChatSummary, NarrativeContext, Repo}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "daily inheritance uses the latest structural anchor and its uncovered seam" do
    chat_id = unique_chat_id()

    insert_summary(
      chat_id,
      ~D[2026-06-01],
      ~D[2026-06-08],
      "Old volume",
      "chronicle_volume"
    )

    insert_summary(
      chat_id,
      ~D[2026-06-08],
      ~D[2026-06-15],
      "Latest weekly",
      "weekly_chronicle"
    )

    insert_summary(chat_id, ~D[2026-06-14], ~D[2026-06-15], "Overlap")
    insert_summary(chat_id, ~D[2026-06-15], ~D[2026-06-16], "First seam")
    insert_summary(chat_id, ~D[2026-06-16], ~D[2026-06-17], "Second seam")

    assert NarrativeContext.for_daily_summary(
             chat_id,
             day_start(~D[2026-06-17])
           )
           |> Enum.map(& &1.summary_text) == [
             "Latest weekly",
             "First seam",
             "Second seam"
           ]
  end

  test "weekly inheritance uses the latest volume and only uncovered weeks" do
    chat_id = unique_chat_id()

    insert_summary(
      chat_id,
      ~D[2026-05-04],
      ~D[2026-05-11],
      "Covered weekly",
      "weekly_chronicle"
    )

    insert_summary(
      chat_id,
      ~D[2026-05-04],
      ~D[2026-05-11],
      "Latest volume",
      "chronicle_volume"
    )

    insert_summary(
      chat_id,
      ~D[2026-05-11],
      ~D[2026-05-18],
      "Uncovered weekly",
      "weekly_chronicle"
    )

    assert NarrativeContext.for_weekly_summary(
             chat_id,
             day_start(~D[2026-05-18])
           )
           |> Enum.map(& &1.summary_text) == [
             "Latest volume",
             "Uncovered weekly"
           ]

    assert NarrativeContext.weekly_chapter_count(
             chat_id,
             day_start(~D[2026-05-18])
           ) == 2
  end

  test "daily inheritance without a structural anchor keeps a bounded local lineage" do
    chat_id = unique_chat_id()

    for offset <- 0..9 do
      date = Date.add(~D[2026-05-01], offset)
      insert_summary(chat_id, date, Date.add(date, 1), "Day #{offset}")
    end

    assert NarrativeContext.for_daily_summary(
             chat_id,
             day_start(~D[2026-05-11])
           )
           |> Enum.map(& &1.summary_text) ==
             Enum.map(3..9, &"Day #{&1}")
  end

  defp insert_summary(chat_id, from_date, to_date, text, kind \\ nil) do
    metadata = if kind, do: %{"kind" => kind}, else: %{}

    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: day_start(from_date),
      to_date: day_start(to_date),
      agent: "claude-opus-4-6",
      summary_text: text,
      message_count: 10,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp day_start(date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp unique_chat_id,
    do: 9_400_000_000 + System.unique_integer([:positive])
end
