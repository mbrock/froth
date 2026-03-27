defmodule Froth.Telegram.BotContextTest do
  use ExUnit.Case, async: false

  alias Froth.Agent
  alias Froth.Agent.Cycle
  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.Analysis
  alias Froth.ChatSummary
  alias Froth.Repo
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.SessionConfig

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "builds a prompt from only the incoming message when the database is empty" do
    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: unique_chat_id(),
          id: 10,
          sender_id: 42,
          text: "hello from telegram",
          date: 1_700_000_100
        ),
        bot_config()
      )

    assert is_list(parts)
    prompt = Enum.join(parts, "")

    assert prompt =~ ~s(<msg message_id="10")
    assert prompt =~ "hello from telegram"
    refute prompt =~ "<summary"
    refute prompt =~ "<active_tasks>"
    refute prompt =~ "<previous_cycle"
  end

  test "accepts synthetic incoming messages with integer sender ids" do
    parts =
      BotContext.for_message(
        %{
          "chat_id" => unique_chat_id(),
          "id" => 10,
          "sender_id" => 0,
          "date" => 1_700_000_100,
          "content" => %{"text" => %{"text" => "[Task completed] agent:123 completed."}}
        },
        bot_config()
      )

    assert is_list(parts)
    assert Enum.join(parts, "") =~ "[Task completed] agent:123 completed."
  end

  test "includes only prior telegram messages before the incoming message date" do
    bot_config = bot_config()
    chat_id = unique_chat_id()

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      101,
      7,
      1_700_000_700,
      "older context"
    )

    insert_telegram_message(bot_config.session_id, chat_id, 102, 8, 1_700_000_800, "still older")

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      103,
      9,
      1_700_000_900,
      "future context leak"
    )

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: "1700000850"
        ),
        bot_config
      )

    assert is_list(parts)

    prompt = Enum.join(parts, "")

    assert prompt =~ "older context"
    assert prompt =~ "still older"
    refute prompt =~ "future context leak"
    assert prompt =~ ~s(<msg message_id="101")
    assert prompt =~ ~s(<msg message_id="102")
    assert prompt =~ ~s(<msg message_id="999")
    assert prompt =~ "fresh message"
    assert prompt =~ "<info>"
  end

  test "loads recent messages without chapters when no chronicle dir is configured" do
    chat_id = unique_chat_id()
    bot_config = bot_config()

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      101,
      7,
      1_700_000_500,
      "older context"
    )

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      102,
      8,
      1_700_000_700,
      "recent context"
    )

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: 1_700_000_850
        ),
        bot_config
      )

    prompt = Enum.join(parts, "")

    refute prompt =~ "<chapter "
    assert prompt =~ "older context"
    assert prompt =~ "recent context"
    assert prompt =~ "fresh message"
  end

  test "can limit recent messages for lightweight bot contexts" do
    chat_id = unique_chat_id()
    bot_config = bot_config(recent_message_limit: 2)

    insert_telegram_message(bot_config.session_id, chat_id, 101, 7, 1_700_000_100, "too old")
    insert_telegram_message(bot_config.session_id, chat_id, 102, 8, 1_700_000_200, "older")
    insert_telegram_message(bot_config.session_id, chat_id, 103, 9, 1_700_000_300, "newer")

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: 1_700_000_400
        ),
        bot_config
      )

    prompt = Enum.join(parts, "")

    refute prompt =~ "too old"
    assert prompt =~ "older"
    assert prompt =~ "newer"
    assert prompt =~ "fresh message"
  end

  test "includes analysis excerpts in normal bot context representation" do
    bot_config = bot_config()
    chat_id = unique_chat_id()

    insert_summary(chat_id, 1_700_000_000, 1_700_000_600, "Earlier summary")

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      101,
      7,
      1_700_000_700,
      "older context"
    )

    insert_analysis(chat_id, 101, "vision", "observed   cat  on    desk with notes")

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: 1_700_000_850
        ),
        bot_config
      )

    prompt = Enum.join(parts, "")
    assert prompt =~ ~s(<analysis )
    assert prompt =~ ~s(type="vision")
    assert prompt =~ "observed cat on desk with notes"
  end

  test "chronicle_dir loads chapters into context" do
    chat_id = unique_chat_id()
    session_id = "test-session-#{System.unique_integer([:positive])}"
    chronicle_dir = chronicle_dir_fixture("ch01-founding": "The founding story", "ch02-war": "The war chapter")

    insert_telegram_message(session_id, chat_id, 101, 8, 1_700_000_700, "recent context")

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: 1_700_000_850
        ),
        Map.put(bot_config(session_id: session_id), :chronicle_dir, chronicle_dir)
      )

    prompt = Enum.join(parts, "")

    assert prompt =~ ~s(<chapter name="ch01-founding">)
    assert prompt =~ "The founding story"
    assert prompt =~ ~s(<chapter name="ch02-war">)
    assert prompt =~ "The war chapter"
    assert prompt =~ "recent context"
  end

  test "attaches cycle traces to the linked recent message and omits send_message noise" do
    bot_config = bot_config()
    chat_id = unique_chat_id()
    reply_to_message_id = 123

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      reply_to_message_id,
      88,
      1_700_001_900,
      "what happened earlier?"
    )

    cycle_id =
      insert_tool_cycle(bot_config.id, chat_id,
        reply_to: reply_to_message_id,
        assistant_blocks: [
          %{
            "type" => "tool_use",
            "id" => "toolu_send",
            "name" => "send_message",
            "input" => %{"text" => "hi"}
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_search",
            "name" => "search",
            "input" => %{"query" => ["froth", "context"]}
          }
        ],
        result_blocks: [
          %{"type" => "tool_result", "tool_use_id" => "toolu_send", "content" => "sent"},
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_search",
            "content" => "found signal"
          }
        ]
      )

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 300,
          sender_id: 88,
          text: "what happened earlier?",
          date: 1_700_002_000
        ),
        bot_config
      )

    assert is_list(parts)
    prompt = Enum.join(parts, "")
    assert Regex.match?(~r/<msg message_id="123".*<cycle cycle_id="#{cycle_id}"/s, prompt)
    assert prompt =~ ~s(<call tool="search">)
    assert prompt =~ ~s({"query":["froth","context"]})
    assert prompt =~ "found signal"
    refute prompt =~ ~s(<call tool="send_message">)
  end

  test "ignores linked cycles that only used send_message" do
    bot_config = bot_config()
    chat_id = unique_chat_id()
    reply_to_message_id = 123

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      reply_to_message_id,
      89,
      1_700_002_000,
      "ping"
    )

    insert_tool_cycle(bot_config.id, chat_id,
      reply_to: reply_to_message_id,
      assistant_blocks: [
        %{
          "type" => "tool_use",
          "id" => "toolu_send",
          "name" => "send_message",
          "input" => %{"text" => "hi"}
        }
      ],
      result_blocks: [
        %{"type" => "tool_result", "tool_use_id" => "toolu_send", "content" => "sent"}
      ]
    )

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 301,
          sender_id: 89,
          text: "ping",
          date: 1_700_002_100
        ),
        bot_config
      )

    assert is_list(parts)
    refute Enum.join(parts, "") =~ "<cycle cycle_id="
  end

  test "returns nil for malformed input" do
    assert BotContext.for_message(%{"chat_id" => "oops"}, bot_config()) == nil
    assert BotContext.for_message(%{"chat_id" => 1}, :not_a_map) == nil
  end

  defp bot_config(opts \\ []) do
    %{
      id: Keyword.get(opts, :id, "charlie"),
      session_id: Keyword.get(opts, :session_id, "test-session"),
      recent_message_limit: Keyword.get(opts, :recent_message_limit)
    }
  end

  defp incoming_message(opts) do
    %{
      "chat_id" => Keyword.fetch!(opts, :chat_id),
      "id" => Keyword.fetch!(opts, :id),
      "date" => Keyword.fetch!(opts, :date),
      "sender_id" => %{"user_id" => Keyword.fetch!(opts, :sender_id)},
      "content" => %{
        "@type" => "messageText",
        "text" => %{"text" => Keyword.fetch!(opts, :text)}
      }
    }
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
    ensure_session(session_id)

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

  defp insert_analysis(chat_id, message_id, type, analysis_text) do
    Repo.insert!(
      Analysis.changeset(%Analysis{}, %{
        type: type,
        chat_id: chat_id,
        message_id: message_id,
        agent: "test-agent",
        analysis_text: analysis_text,
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    )
  end

  defp ensure_session(session_id) do
    case Repo.get(SessionConfig, session_id) do
      nil ->
        Repo.insert!(
          SessionConfig.changeset(%SessionConfig{}, %{
            id: session_id,
            api_id: 1234,
            api_hash: "test-hash",
            bot_token: "test-token",
            enabled: true
          })
        )

      _session ->
        :ok
    end
  end

  defp insert_tool_cycle(bot_id, chat_id, opts) do
    cycle = Repo.insert!(%Cycle{})

    user_msg =
      Repo.insert!(%AgentMessage{
        role: :user,
        content: AgentMessage.wrap("start")
      })

    assistant_msg =
      Repo.insert!(%AgentMessage{
        role: :agent,
        content: AgentMessage.wrap(Keyword.fetch!(opts, :assistant_blocks)),
        parent_id: user_msg.id
      })

    result_msg =
      Repo.insert!(%AgentMessage{
        role: :user,
        content: AgentMessage.wrap(Keyword.fetch!(opts, :result_blocks)),
        parent_id: assistant_msg.id
      })

    Agent.append_event(cycle, %{head_id: result_msg.id, message_id: result_msg.id})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: bot_id,
      chat_id: chat_id,
      reply_to: Keyword.get(opts, :reply_to, 123)
    })

    cycle.id
  end

  defp unique_chat_id do
    9_000_000_000 + System.unique_integer([:positive])
  end

  defp chronicle_dir_fixture(chapters) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "froth-chronicle-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    for {name, text} <- chapters do
      File.write!(Path.join(dir, "#{name}.md"), text)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
