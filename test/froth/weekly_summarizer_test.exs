defmodule Froth.WeeklySummarizerTest do
  use ExUnit.Case, async: true

  alias Froth.{ChatSummary, Repo, WeeklySummarizer}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "pending ranges bridge the manual chronicle then align Monday through Sunday" do
    chat_id = unique_chat_id()

    assert WeeklySummarizer.pending_ranges(chat_id, ~D[2026-04-13]) == [
             {~D[2026-03-24], ~D[2026-03-29]},
             {~D[2026-03-30], ~D[2026-04-05]},
             {~D[2026-04-06], ~D[2026-04-12]}
           ]
  end

  test "pending ranges continue after the latest stored weekly chapter" do
    chat_id = unique_chat_id()
    insert_weekly(chat_id, ~D[2026-03-24], ~D[2026-03-29])

    assert WeeklySummarizer.pending_ranges(chat_id, ~D[2026-04-06]) == [
             {~D[2026-03-30], ~D[2026-04-05]}
           ]
  end

  test "Sunday is not eligible until Monday UTC" do
    chat_id = unique_chat_id()

    assert WeeklySummarizer.pending_ranges(chat_id, ~D[2026-03-29]) == []

    assert WeeklySummarizer.pending_ranges(chat_id, ~D[2026-03-30]) == [
             {~D[2026-03-24], ~D[2026-03-29]}
           ]
  end

  defp insert_weekly(chat_id, from_date, to_date) do
    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: day_start(from_date),
      to_date: day_start(Date.add(to_date, 1)),
      agent: "claude-opus-4-6",
      summary_text: "A weekly chapter.",
      message_count: 10,
      metadata: %{"kind" => WeeklySummarizer.kind()}
    })
    |> Repo.insert!()
  end

  defp day_start(date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp unique_chat_id, do: 9_200_000_000 + System.unique_integer([:positive])
end
