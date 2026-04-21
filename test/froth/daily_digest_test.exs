defmodule Froth.DailyDigestTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Froth.{ChatSummary, DailyDigest, Event, Repo}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "run_now summarizes a pending UTC day, generates headlines when missing, sends one HTML digest, and records the send" do
    test_pid = self()
    chat_id = unique_chat_id()
    date = ~D[2026-03-22]
    digest_dir = unique_digest_dir()

    on_exit(fn -> File.rm_rf(digest_dir) end)

    assert {:ok, result} =
             DailyDigest.run_now(
               today: ~D[2026-03-23],
               chat_id: chat_id,
               session_id: "charlie",
               digest_dir: digest_dir,
               pending_summary_dates_fun: fn ^chat_id, ~D[2026-03-23] ->
                 [date]
               end,
               summarize_day_fun: fn ^chat_id, ^date ->
                 {:ok,
                  insert_summary(
                    chat_id,
                    date,
                    "Charlie wrote the whole messy chronicle."
                  )}
               end,
               extract_headlines_fun: fn ^chat_id, opts ->
                 send(test_pid, {:extract_headlines, opts})

                 insert_headlines(chat_id, date, [
                   %{"emoji" => "🚀", "title" => "Launch day"}
                 ])

                 {:ok, :registered}
               end,
               send_document_fun: fn session_id, sent_chat_id, path, opts ->
                 send(
                   test_pid,
                   {:send_document, session_id, sent_chat_id, path, opts}
                 )

                 {:ok, %{"id" => 444}}
               end
             )

    assert result.pending_dates == [date]
    assert result.summarized_dates == [date]
    assert result.no_message_dates == []
    assert result.sent_dates == [date]

    assert_receive {:extract_headlines, extract_opts}, 5_000
    assert extract_opts[:spam] == false

    assert_receive {:send_document, "charlie", ^chat_id, path, opts}, 5_000
    assert path == Path.join(digest_dir, "chat-#{chat_id}-2026-03-22.html")
    assert File.read!(path) =~ "Charlie wrote the whole messy chronicle."
    assert opts[:caption] =~ "2026-03-22"
    assert opts[:caption] =~ "🚀 Launch day"
    assert opts[:caption] =~ "Summary attached as HTML."
    assert length(opts[:caption_entities]) == 2

    assert Repo.exists?(
             from(e in Event,
               where:
                 e.event == "froth.daily_digest.sent" and
                   fragment(
                     "?->>'chat_id' = ?",
                     e.metadata,
                     ^Integer.to_string(chat_id)
                   ) and
                   fragment("?->>'date' = ?", e.metadata, "2026-03-22"),
               select: 1
             ),
             log: false
           )
  end

  test "run_now re-sends an unsent stored summary without re-running headlines when they already exist" do
    test_pid = self()
    chat_id = unique_chat_id()
    date = ~D[2026-03-21]
    digest_dir = unique_digest_dir()

    summary =
      insert_summary(
        chat_id,
        date,
        "Stored summary waiting for Charlie to post it."
      )

    insert_headlines(chat_id, date, [
      %{
        "emoji" => "🛠️",
        "title" => "Repair shift",
        "from_time" => "2026-03-21T09:00:00Z",
        "to_time" => "2026-03-21T09:45:00Z"
      }
    ])

    on_exit(fn -> File.rm_rf(digest_dir) end)

    assert {:ok, result} =
             DailyDigest.run_now(
               today: ~D[2026-03-23],
               chat_id: chat_id,
               session_id: "charlie",
               digest_dir: digest_dir,
               pending_summary_dates_fun: fn ^chat_id, ~D[2026-03-23] ->
                 []
               end,
               summarize_day_fun: fn _chat_id, _date ->
                 flunk("summarize_day should not run")
               end,
               extract_headlines_fun: fn _chat_id, _opts ->
                 send(test_pid, :extract_called)
                 {:ok, :unexpected}
               end,
               send_document_fun: fn "charlie", ^chat_id, path, opts ->
                 send(test_pid, {:send_document, path, opts})
                 {:ok, %{"id" => 445}}
               end
             )

    refute_receive :extract_called

    assert result.pending_dates == []
    assert result.summarized_dates == []
    assert result.no_message_dates == []
    assert result.sent_dates == [date]

    assert_receive {:send_document, path, opts}, 5_000
    assert path == Path.join(digest_dir, "chat-#{chat_id}-2026-03-21.html")
    assert File.read!(path) =~ summary.summary_text
    assert opts[:caption] =~ "🛠️ Repair shift (09:00-09:45 UTC)"
  end

  test "next_run_at stays explicitly in UTC" do
    assert DailyDigest.next_run_at(~U[2026-03-26 23:59:59Z], ~T[00:05:00]) ==
             ~U[2026-03-27 00:05:00Z]

    assert DailyDigest.next_run_at(~U[2026-03-26 00:04:59Z], ~T[00:05:00]) ==
             ~U[2026-03-26 00:05:00Z]
  end

  defp insert_summary(chat_id, date, text) do
    from_unix =
      DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    to_unix =
      DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix()

    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: from_unix,
      to_date: to_unix,
      agent: "claude-opus-4-6",
      summary_text: text,
      message_count: 1
    })
    |> Repo.insert!()
  end

  defp insert_headlines(chat_id, date, headlines) do
    %Event{}
    |> Event.changeset(%{
      event: "froth.headlines.registered",
      metadata: %{
        "date" => Date.to_iso8601(date),
        "chat_id" => Integer.to_string(chat_id),
        "headlines" => headlines
      },
      measurements: %{"count" => length(headlines)}
    })
    |> Repo.insert!()
  end

  defp unique_chat_id do
    9_100_000_000 + System.unique_integer([:positive])
  end

  defp unique_digest_dir do
    Path.join(
      System.tmp_dir!(),
      "froth-daily-digest-#{System.unique_integer([:positive])}"
    )
  end
end
