defmodule Froth.Telegram.BotContextTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.Cycle
  alias Froth.Analysis
  alias Froth.ChatSummary
  alias Froth.Repo
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.SessionConfig

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
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

    assert prompt =~ ~s(<text id=tg:10)
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
          "content" => %{
            "text" => %{"text" => "[Task completed] agent:123 completed."}
          }
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

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      102,
      8,
      1_700_000_800,
      "still older"
    )

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
    assert prompt =~ ~s(<text id=tg:101)
    assert prompt =~ ~s(<text id=tg:102)
    assert prompt =~ ~s(<text id=tg:999)
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

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      101,
      7,
      1_700_000_100,
      "too old"
    )

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      102,
      8,
      1_700_000_200,
      "older"
    )

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      103,
      9,
      1_700_000_300,
      "newer"
    )

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

  test "anchored recent message windows only advance on the configured batch size" do
    chat_id = unique_chat_id()

    opts = [
      telegram_session_id: "test-session",
      recent_message_limit: 3,
      recent_message_anchor_size: 2
    ]

    insert_telegram_message(
      "test-session",
      chat_id,
      101,
      7,
      1_700_000_100,
      "m1"
    )

    insert_telegram_message(
      "test-session",
      chat_id,
      102,
      7,
      1_700_000_200,
      "m2"
    )

    insert_telegram_message(
      "test-session",
      chat_id,
      103,
      7,
      1_700_000_300,
      "m3"
    )

    insert_telegram_message(
      "test-session",
      chat_id,
      104,
      7,
      1_700_000_400,
      "m4"
    )

    insert_telegram_message(
      "test-session",
      chat_id,
      105,
      7,
      1_700_000_500,
      "m5"
    )

    parts_before =
      chat_id
      |> BotContext.render_parts(opts)

    prompt_before = Enum.join(parts_before, "")
    refute prompt_before =~ "m1"
    refute prompt_before =~ "m2"
    assert prompt_before =~ "m3"
    assert prompt_before =~ "m4"
    assert prompt_before =~ "m5"

    insert_telegram_message(
      "test-session",
      chat_id,
      106,
      7,
      1_700_000_600,
      "m6"
    )

    parts_after_append =
      chat_id
      |> BotContext.render_parts(opts)

    prompt_after_append = Enum.join(parts_after_append, "")
    assert prompt_after_append =~ "m3"
    assert prompt_after_append =~ "m4"
    assert prompt_after_append =~ "m5"
    assert prompt_after_append =~ "m6"

    stable_before = Enum.take(parts_before, length(parts_before) - 1)

    stable_after_append =
      Enum.take(parts_after_append, length(parts_before) - 1)

    assert stable_after_append == stable_before

    insert_telegram_message(
      "test-session",
      chat_id,
      107,
      7,
      1_700_000_700,
      "m7"
    )

    prompt_after_roll =
      chat_id
      |> BotContext.render_parts(opts)
      |> Enum.join("")

    refute prompt_after_roll =~ "m3"
    refute prompt_after_roll =~ "m4"
    assert prompt_after_roll =~ "m5"
    assert prompt_after_roll =~ "m6"
    assert prompt_after_roll =~ "m7"
  end

  test "time and mass recent windows keep a recent horizon and trim by bucketed text mass" do
    chat_id = unique_chat_id()

    bot_config =
      bot_config(
        recent_window_target_hours: 4,
        recent_window_min_hours: 1,
        recent_window_backfill_hours: 8,
        recent_window_char_budget: 250,
        recent_window_bucket_minutes: 30
      )

    base_unix = 1_700_000_000

    for idx <- 0..7 do
      insert_telegram_message(
        bot_config.session_id,
        chat_id,
        100 + idx,
        7,
        base_unix + idx * 1800 + 60,
        String.duplicate("a", 100)
      )
    end

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: base_unix + 8 * 1800
        ),
        bot_config
      )

    prompt = Enum.join(parts, "")

    refute prompt =~ ~s(id=tg:100 )
    refute prompt =~ ~s(id=tg:101 )
    refute prompt =~ ~s(id=tg:102 )
    refute prompt =~ ~s(id=tg:103 )
    refute prompt =~ ~s(id=tg:104 )
    refute prompt =~ ~s(id=tg:105 )
    assert prompt =~ ~s(id=tg:106 )
    assert prompt =~ ~s(id=tg:107 )
    assert prompt =~ ~s(id=tg:999 )
  end

  test "orders tied session messages deterministically by message id" do
    chat_id = unique_chat_id()
    bot_config = bot_config(recent_message_limit: 10)
    tied_inserted_at = ~N[2026-03-28 12:44:43]

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      200,
      7,
      1_700_000_100,
      "first"
    )

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      202,
      7,
      1_700_000_200,
      "higher id"
    )

    insert_telegram_message(
      bot_config.session_id,
      chat_id,
      201,
      8,
      1_700_000_200,
      "lower id"
    )

    set_message_inserted_at(
      bot_config.session_id,
      chat_id,
      202,
      tied_inserted_at
    )

    set_message_inserted_at(
      bot_config.session_id,
      chat_id,
      201,
      tied_inserted_at
    )

    parts =
      BotContext.for_message(
        incoming_message(
          chat_id: chat_id,
          id: 999,
          sender_id: 42,
          text: "fresh message",
          date: 1_700_000_300
        ),
        bot_config
      )

    prompt = Enum.join(parts, "")
    lower_idx = match_index(prompt, ~s(<text id=tg:201))
    higher_idx = match_index(prompt, ~s(<text id=tg:202))

    assert prompt =~ ~s(<text id=tg:201)
    assert prompt =~ ~s(<text id=tg:202)
    assert is_integer(lower_idx)
    assert is_integer(higher_idx)
    assert lower_idx < higher_idx
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

    insert_analysis(
      chat_id,
      101,
      "vision",
      "observed   cat  on    desk with notes"
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
    assert prompt =~ ~s(<analysis )
    assert prompt =~ ~s(type=vision)
    assert prompt =~ "observed   cat  on    desk with notes"
  end

  test "chronicle_dir loads chapters into context" do
    chat_id = unique_chat_id()
    session_id = "test-session-#{System.unique_integer([:positive])}"

    chronicle_dir =
      chronicle_dir_fixture(
        "ch01-founding": "The founding story",
        "ch02-war": "The war chapter"
      )

    insert_telegram_message(
      session_id,
      chat_id,
      101,
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
        Map.put(
          bot_config(session_id: session_id),
          :chronicle_dir,
          chronicle_dir
        )
      )

    prompt = Enum.join(parts, "")

    assert prompt =~ ~s(<chapter name=ch01-founding>)
    assert prompt =~ "The founding story"
    assert prompt =~ ~s(<chapter name=ch02-war>)
    assert prompt =~ "The war chapter"
    assert prompt =~ "recent context"
  end

  test "database-backed weekly chronicles follow the manual chapters" do
    chat_id = unique_chat_id()
    session_id = "test-session-#{System.unique_integer([:positive])}"
    from_date = ~D[2026-03-24]
    to_date = ~D[2026-03-30]

    Repo.insert!(
      ChatSummary.changeset(%ChatSummary{}, %{
        chat_id: chat_id,
        from_date:
          DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
          |> DateTime.to_unix(),
        to_date:
          DateTime.new!(to_date, ~T[00:00:00], "Etc/UTC")
          |> DateTime.to_unix(),
        agent: "claude-opus-4-6",
        summary_text: "The first automatic weekly chapter.",
        message_count: 42,
        metadata: %{"kind" => "weekly_chronicle"}
      })
    )

    parts =
      BotContext.render_parts(chat_id,
        telegram_session_id: session_id,
        chronicle_dir: nil
      )

    prompt = Enum.join(parts, "")
    assert prompt =~ ~s(<chapter name=week-2026-03-24-to-2026-03-29>)
    assert prompt =~ "The first automatic weekly chapter."
  end

  test "weekly chapters are followed by a fixed rolling tail of daily summaries" do
    chat_id = unique_chat_id()

    Repo.insert!(
      ChatSummary.changeset(%ChatSummary{}, %{
        chat_id: chat_id,
        from_date: day_start_unix(~D[2026-03-30]),
        to_date: day_start_unix(~D[2026-04-06]),
        agent: "claude-opus-4-6",
        summary_text: "The weekly chapter.",
        message_count: 70,
        metadata: %{"kind" => "weekly_chronicle"}
      })
    )

    for offset <- 0..7 do
      date = Date.add(~D[2026-04-01], offset)

      insert_summary(
        chat_id,
        day_start_unix(date),
        day_start_unix(Date.add(date, 1)),
        "Daily summary #{date}"
      )
    end

    prompt =
      BotContext.render_parts(chat_id,
        chronicle_dir: nil,
        daily_summary_limit: 7
      )
      |> Enum.join("")

    weekly_pos = position(prompt, "The weekly chapter.")
    first_daily_pos = position(prompt, "Daily summary 2026-04-02")

    assert weekly_pos < first_daily_pos
    refute prompt =~ "Daily summary 2026-04-01"

    for offset <- 1..7 do
      date = Date.add(~D[2026-04-01], offset)
      assert prompt =~ ~s(<daily-summary date=#{date}>)
      assert prompt =~ "Daily summary #{date}"
    end
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
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_send",
            "content" => "sent"
          },
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
    assert prompt =~ ~s(<text id=tg:123)
    assert prompt =~ ~s(<cycle id=#{cycle_id} for=tg:123)
    assert prompt =~ ~s(<call tool=search>)
    assert prompt =~ "<query>"
    assert prompt =~ "froth"
    assert prompt =~ "context"
    assert prompt =~ "found signal"
    refute prompt =~ ~s(<call tool=send_message>)
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
        %{
          "type" => "tool_result",
          "tool_use_id" => "toolu_send",
          "content" => "sent"
        }
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
    refute Enum.join(parts, "") =~ "<cycle id="
  end

  test "returns nil for malformed input" do
    assert BotContext.for_message(%{"chat_id" => "oops"}, bot_config()) == nil
    assert BotContext.for_message(%{"chat_id" => 1}, :not_a_map) == nil
  end

  defp bot_config(opts \\ []) do
    %{
      id: Keyword.get(opts, :id, "charlie"),
      session_id: Keyword.get(opts, :session_id, "test-session"),
      recent_message_limit: Keyword.get(opts, :recent_message_limit),
      recent_message_anchor_size:
        Keyword.get(opts, :recent_message_anchor_size),
      recent_window_target_hours:
        Keyword.get(opts, :recent_window_target_hours),
      recent_window_min_hours: Keyword.get(opts, :recent_window_min_hours),
      recent_window_backfill_hours:
        Keyword.get(opts, :recent_window_backfill_hours),
      recent_window_char_budget:
        Keyword.get(opts, :recent_window_char_budget),
      recent_window_bucket_minutes:
        Keyword.get(opts, :recent_window_bucket_minutes)
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

  defp day_start_unix(date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp position(text, needle) do
    {position, _length} = :binary.match(text, needle)
    position
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

  defp set_message_inserted_at(session_id, chat_id, message_id, inserted_at) do
    from(m in TelegramMessage,
      where:
        m.telegram_session_id == ^session_id and
          m.chat_id == ^chat_id and
          m.message_id == ^message_id
    )
    |> Repo.update_all(set: [inserted_at: inserted_at])
  end

  defp match_index(haystack, needle)
       when is_binary(haystack) and is_binary(needle) do
    case :binary.match(haystack, needle) do
      {idx, _len} -> idx
      :nomatch -> nil
    end
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

    assistant_blocks = Keyword.fetch!(opts, :assistant_blocks)
    result_blocks = Keyword.fetch!(opts, :result_blocks)

    Agent.append_message(cycle, :user, "start", nil, 0)
    Agent.append_message(cycle, :agent, assistant_blocks, nil, 1)
    Agent.append_message(cycle, :user, result_blocks, nil, 2)

    results_by_id =
      Map.new(result_blocks, fn block ->
        {block["tool_use_id"], block}
      end)

    assistant_blocks
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.with_index(3)
    |> Enum.each(fn {tool_use, seq} ->
      result = Map.fetch!(results_by_id, tool_use["id"])

      Agent.append_event(
        cycle,
        %{
          kind: "tool.completed",
          tool_use_id: tool_use["id"],
          data: %{
            "tool_name" => tool_use["name"],
            "tool_use_id" => tool_use["id"],
            "input" => tool_use["input"],
            "result_type" =>
              if(result["is_error"], do: "error", else: "text"),
            "result" => result["content"]
          }
        },
        seq
      )
    end)

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
