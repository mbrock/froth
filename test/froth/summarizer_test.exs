defmodule Froth.SummarizerTest do
  use ExUnit.Case, async: false

  alias Froth.ChatSummary
  alias Froth.Repo
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.SessionConfig

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "context_parts uses template page breaks for summaries and recent transcript messages" do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    chat_id = unique_chat_id()

    ensure_session(session_id)
    insert_summary(chat_id, 1_700_000_000, 1_700_000_600, "Earlier summary")
    insert_telegram_message(session_id, chat_id, 101, 7, 1_700_000_700, "older context")
    insert_telegram_message(session_id, chat_id, 102, 8, 1_700_000_800, "still older")
    insert_telegram_message(session_id, chat_id, 103, 9, 1_700_000_900, "future context leak")

    Process.put({:bot_context_chat_name, session_id, chat_id}, "Froth chat")
    Process.put({:bot_context_user_label, session_id, 7}, "@seven")
    Process.put({:bot_context_user_label, session_id, 8}, "@eight")

    opts = [
      telegram_session_id: session_id,
      before_unix: 1_700_000_850
    ]

    parts = BotContext.context_parts(chat_id, opts)

    assert length(parts) == 4

    assert Enum.at(parts, 0) =~ "<summary date="
    assert Enum.at(parts, 0) =~ "Earlier summary"

    assert Enum.at(parts, 1) =~ "<chat_context>"
    assert Enum.at(parts, 1) =~ "chat_id=#{chat_id}"
    assert Enum.at(parts, 1) =~ "chat_name=Froth chat"
    assert Enum.at(parts, 1) =~ "- @seven [id=7]"
    refute Enum.at(parts, 1) =~ "<msg "

    assert Enum.at(parts, 2) =~ ~s(<msg message_id="101")
    assert Enum.at(parts, 2) =~ "older context"

    assert Enum.at(parts, 3) =~ ~s(time="2023-11-14 22:26 UTC")
    assert Enum.at(parts, 3) =~ "@eight"
    assert Enum.at(parts, 3) =~ "still older"
    assert Enum.at(parts, 3) =~ ~s(<msg message_id="102")

    refute Enum.join(parts, "") =~ "future context leak"
    assert BotContext.context(chat_id, opts) == Enum.join(parts, "")
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

  defp insert_telegram_message(session_id, chat_id, message_id, sender_id, date, text) do
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

  defp unique_chat_id do
    9_100_000_000 + System.unique_integer([:positive])
  end
end
