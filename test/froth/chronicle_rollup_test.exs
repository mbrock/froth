defmodule Froth.ChronicleRollupTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.BotContext
  alias Froth.Telegram.Message
  alias Froth.Telegram.SessionConfig
  alias Froth.{ChatSummary, ChronicleRollup, Repo}

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "pending sources preserve the newest detailed weeks" do
    chat_id = unique_chat_id()
    weeks = insert_consecutive_weeklies(chat_id, ~D[2026-03-23], 10)

    assert ChronicleRollup.pending_source_weeklies(chat_id)
           |> Enum.map(& &1.id) == Enum.map(Enum.take(weeks, 6), & &1.id)
  end

  test "covered weeklies collapse into a volume without overlapping daily context" do
    chat_id = unique_chat_id()
    weeks = insert_consecutive_weeklies(chat_id, ~D[2026-03-23], 6)
    [first, second | _] = weeks

    insert_volume(chat_id, first, second)

    latest_week = List.last(weeks)
    overlapping_day = latest_week.from_date
    next_day = latest_week.to_date

    insert_daily(chat_id, overlapping_day, "overlapping daily detail")
    insert_daily(chat_id, next_day, "new daily detail")

    prompt =
      BotContext.render_parts(chat_id,
        chronicle_dir: nil,
        daily_summary_limit: 7,
        telegram_session_id: "rollup-test"
      )
      |> Enum.join("\n")

    assert prompt =~ "<chapter name=volume-2026-03-23-to-2026-04-05>"
    assert prompt =~ "Closed volume."
    refute prompt =~ "Weekly chapter 1"
    refute prompt =~ "Weekly chapter 2"
    assert prompt =~ "Weekly chapter 3"
    assert prompt =~ "Weekly chapter 6"
    refute prompt =~ "overlapping daily detail"
    assert prompt =~ "new daily detail"
  end

  test "raw context begins exactly after the latest narrative boundary" do
    chat_id = unique_chat_id()
    session_id = "rollup-test"
    boundary = day_start(~D[2026-07-29])
    insert_session(session_id)

    insert_daily(
      chat_id,
      day_start(~D[2026-07-28]),
      "Closed daily narrative."
    )

    insert_message(session_id, chat_id, 1, boundary - 1, "already summarized")
    insert_message(session_id, chat_id, 2, boundary, "first unfolding turn")

    insert_message(
      session_id,
      chat_id,
      3,
      boundary + 1,
      "second unfolding turn"
    )

    prompt =
      BotContext.render_parts(chat_id,
        chronicle_dir: nil,
        daily_summary_limit: 7,
        telegram_session_id: session_id,
        recent_message_limit: 1
      )
      |> Enum.join("\n")

    refute prompt =~ "already summarized"
    assert prompt =~ "first unfolding turn"
    assert prompt =~ "second unfolding turn"
  end

  defp insert_consecutive_weeklies(chat_id, first_monday, count) do
    Enum.map(0..(count - 1), fn offset ->
      from_date = Date.add(first_monday, offset * 7)
      to_date = Date.add(from_date, 7)

      insert_summary(
        chat_id,
        from_date,
        to_date,
        "Weekly chapter #{offset + 1}",
        kind: "weekly_chronicle"
      )
    end)
  end

  defp insert_volume(chat_id, first, last) do
    insert_summary(
      chat_id,
      date(first.from_date),
      date(last.to_date),
      "Closed volume.",
      kind: ChronicleRollup.kind()
    )
  end

  defp insert_daily(chat_id, from_unix, text) do
    from_date = date(from_unix)
    insert_summary(chat_id, from_date, Date.add(from_date, 1), text)
  end

  defp insert_summary(chat_id, from_date, to_date, text, opts \\ []) do
    %ChatSummary{}
    |> ChatSummary.changeset(%{
      chat_id: chat_id,
      from_date: day_start(from_date),
      to_date: day_start(to_date),
      agent: "claude-opus-4-6",
      summary_text: text,
      message_count: 10,
      metadata:
        case Keyword.get(opts, :kind) do
          nil -> %{}
          kind -> %{"kind" => kind}
        end
    })
    |> Repo.insert!()
  end

  defp insert_message(session_id, chat_id, message_id, unix, text) do
    %Message{}
    |> Message.changeset(%{
      telegram_session_id: session_id,
      chat_id: chat_id,
      message_id: message_id,
      sender_id: 42,
      date: unix,
      raw: %{
        "content" => %{
          "@type" => "messageText",
          "text" => %{"text" => text}
        }
      }
    })
    |> Repo.insert!()
  end

  defp insert_session(session_id) do
    %SessionConfig{}
    |> SessionConfig.changeset(%{
      id: session_id,
      api_id: 1,
      api_hash: "test",
      bot_token: "test"
    })
    |> Repo.insert!()
  end

  defp day_start(date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp date(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_date()

  defp unique_chat_id,
    do: 9_300_000_000 + System.unique_integer([:positive])
end
