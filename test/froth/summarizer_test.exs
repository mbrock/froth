defmodule Froth.SummarizerTest do
  use ExUnit.Case, async: true

  alias Froth.ChatSummary
  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.Repo
  alias Froth.Summarizer
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.SessionConfig
  alias Froth.Telegram.Username

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "context_parts splits recent transcript messages and trailing chat info into stable parts" do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    chat_id = unique_chat_id()

    ensure_session(session_id)
    insert_summary(chat_id, 1_700_000_000, 1_700_000_600, "Earlier summary")

    insert_telegram_message(
      session_id,
      chat_id,
      101,
      7,
      1_700_000_700,
      "older context"
    )

    insert_telegram_message(
      session_id,
      chat_id,
      102,
      8,
      1_700_000_800,
      "still older"
    )

    insert_telegram_message(
      session_id,
      chat_id,
      103,
      9,
      1_700_000_900,
      "future context leak"
    )

    insert_username(7, "seven")
    insert_username(8, "eight")

    Process.put({:chat_name, session_id, chat_id}, "Froth chat")

    opts = [
      telegram_session_id: session_id,
      before_unix: 1_700_000_850
    ]

    parts = BotContext.render_parts(chat_id, opts)

    assert length(parts) == 3

    assert Enum.at(parts, 0) =~ ~s(<text id=tg:101)
    assert Enum.at(parts, 0) =~ "2023-11-14 22:25 UTC"
    assert Enum.at(parts, 0) =~ "@seven"
    assert Enum.at(parts, 0) =~ "older context"

    assert Enum.at(parts, 1) =~ ~s(<text id=tg:102)
    assert Enum.at(parts, 1) =~ "2023-11-14 22:26 UTC"
    assert Enum.at(parts, 1) =~ "@eight"
    assert Enum.at(parts, 1) =~ "still older"

    assert Enum.at(parts, 2) =~ "<info>"

    refute Enum.join(parts, "") =~ "future context leak"
    refute Enum.join(parts, "") =~ "<summary"

    assert Enum.join(BotContext.render_parts(chat_id, opts), "") ==
             Enum.join(parts, "")
  end

  test "pending_summary_dates returns missing days after the latest summary through yesterday" do
    chat_id = unique_chat_id()

    insert_summary(
      chat_id,
      day_start_unix(~D[2026-03-07]),
      day_start_unix(~D[2026-03-08]),
      "March 7 summary"
    )

    assert Summarizer.pending_summary_dates(chat_id, ~D[2026-03-09]) == [
             ~D[2026-03-08]
           ]
  end

  test "pending_summary_dates batches multiple missing days" do
    chat_id = unique_chat_id()

    insert_summary(
      chat_id,
      day_start_unix(~D[2026-03-05]),
      day_start_unix(~D[2026-03-06]),
      "March 5 summary"
    )

    assert Summarizer.pending_summary_dates(chat_id, ~D[2026-03-09]) == [
             ~D[2026-03-06],
             ~D[2026-03-07],
             ~D[2026-03-08]
           ]
  end

  test "pending_summary_dates keys off the summarized day even when coverage ends before midnight" do
    chat_id = unique_chat_id()

    insert_summary(
      chat_id,
      day_start_unix(~D[2026-03-07]),
      day_start_unix(~D[2026-03-07]) + 43_200,
      "Partial March 7 summary"
    )

    assert Summarizer.pending_summary_dates(chat_id, ~D[2026-03-09]) == [
             ~D[2026-03-08]
           ]
  end

  test "pending_summary_dates returns an empty list when yesterday is already covered" do
    chat_id = unique_chat_id()

    insert_summary(
      chat_id,
      day_start_unix(~D[2026-03-08]),
      day_start_unix(~D[2026-03-09]),
      "March 8 summary"
    )

    assert Summarizer.pending_summary_dates(chat_id, ~D[2026-03-09]) == []
  end

  test "preliminary daily summary is amended in place and finalized after midnight" do
    test_pid = self()
    chat_id = unique_chat_id()
    session_id = "test-session-#{System.unique_integer([:positive])}"
    date = ~D[2026-08-04]
    day_start = day_start_unix(date)

    ensure_session(session_id)

    insert_summary(
      chat_id,
      day_start_unix(Date.add(date, -1)),
      day_start,
      "The previous completed day."
    )

    insert_telegram_message(
      session_id,
      chat_id,
      201,
      7,
      day_start + 60,
      "The day begins noisily."
    )

    agent_run_fun = fn message, _config ->
      send(test_pid, {:summary_prompt, AgentMessage.extract_text(message)})

      {%{id: "cycle-#{System.unique_integer([:positive])}"},
       [{:message, AgentMessage.agent("A provisional account of the day.")}]}
    end

    assert {:ok, first} =
             Summarizer.maybe_summarize_preliminary(chat_id,
               now: DateTime.from_unix!(day_start + 120),
               char_threshold: 1,
               agent_run_fun: agent_run_fun
             )

    assert first.metadata["kind"] == "preliminary_daily"
    assert_receive {:summary_prompt, first_prompt}
    assert first_prompt =~ "preliminary summary of the current UTC day"

    insert_telegram_message(
      session_id,
      chat_id,
      202,
      8,
      day_start + 180,
      "The conversation keeps growing."
    )

    assert {:ok, amended} =
             Summarizer.maybe_summarize_preliminary(chat_id,
               now: DateTime.from_unix!(day_start + 240),
               char_threshold: 1,
               agent_run_fun: agent_run_fun
             )

    assert amended.id == first.id
    assert amended.to_date > first.to_date

    assert Summarizer.pending_summary_dates(chat_id, Date.add(date, 1)) == [
             date
           ]

    assert {:ok, final} =
             Summarizer.summarize_day(chat_id, date,
               agent_run_fun: agent_run_fun
             )

    assert final.id == first.id
    refute Map.has_key?(final.metadata, "kind")
    assert_receive {:summary_prompt, _amended_prompt}
    assert_receive {:summary_prompt, final_prompt}
    refute final_prompt =~ "preliminary summary of the current UTC day"
  end

  defp insert_summary(chat_id, from_date, to_date, summary_text) do
    Repo.insert!(
      ChatSummary.changeset(%ChatSummary{}, %{
        chat_id: chat_id,
        from_date: from_date,
        to_date: to_date,
        agent: "claude",
        summary_text: summary_text,
        message_count: 2
      })
    )
  end

  defp insert_telegram_message(
         session_id,
         chat_id,
         message_id,
         sender_id,
         date,
         text
       ) do
    Repo.insert!(
      TelegramMessage.changeset(%TelegramMessage{}, %{
        telegram_session_id: session_id,
        chat_id: chat_id,
        message_id: message_id,
        sender_id: sender_id,
        date: date,
        raw: %{
          "content" => %{
            "@type" => "messageText",
            "text" => %{"text" => text}
          }
        }
      })
    )
  end

  defp ensure_session(session_id) do
    Repo.insert!(
      SessionConfig.changeset(%SessionConfig{}, %{
        id: session_id,
        api_id: 1234,
        api_hash: "test-hash",
        bot_token: "test-token",
        enabled: true
      })
    )
  end

  defp insert_username(user_id, username) do
    Repo.insert!(
      Username.changeset(%Username{}, %{
        user_id: user_id,
        username: username,
        label: "@#{username}"
      })
    )
  end

  defp unique_chat_id do
    9_100_000_000 + System.unique_integer([:positive])
  end

  defp day_start_unix(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end
end
