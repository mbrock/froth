defmodule FrothWeb.TimelineLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Froth.Agent
  alias Froth.Agent.Cycle
  alias Froth.Context.Block
  alias Froth.Repo
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.Message, as: TelegramMessage
  alias Froth.Telegram.SessionConfig
  alias Froth.Telegram.Username

  test "renders highlighted elixir eval inputs and value outputs in cycle timeline entries", %{
    conn: conn
  } do
    session_id = "charlie"
    chat_id = unique_chat_id()
    sender_id = 700_000_000 + System.unique_integer([:positive])
    now = DateTime.utc_now() |> DateTime.to_unix()

    ensure_session(session_id)
    ensure_username(sender_id, "Alice", session_id)

    insert_telegram_message(session_id, chat_id, 1_001, sender_id, now - 5, "run a quick eval")

    cycle = Repo.insert!(%Cycle{})

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: "charlie",
      chat_id: chat_id,
      reply_to: 1_001
    })

    input = %{
      "code" => ~s|for f <- ["phoenix.ex", "ecto.ex", "logs.ex", "eval.ex"] do\n  f\nend|,
      "session_id" => "eval_session_demo"
    }

    blocks = [
      Block.new([kind: "io", session: "eval_session_demo"], "stdout from eval"),
      Block.new([kind: "value", session: "eval_session_demo"], "[2, 3]")
    ]

    Agent.append_event(
      cycle,
      %{
        kind: "tool.completed",
        tool_use_id: "toolu_eval_1",
        data: %{
          "cycle_id" => cycle.id,
          "tool_name" => "elixir_eval",
          "tool_use_id" => "toolu_eval_1",
          "input" => input,
          "input_keys" => Enum.sort(Map.keys(input)),
          "result_type" => "blocks",
          "result" => %{"blocks" => Enum.map(blocks, &Block.to_map/1)}
        }
      },
      1
    )

    {:ok, view, _html} = live(conn, ~p"/froth/timeline?chat_id=#{chat_id}")

    assert has_element?(view, "#c-#{cycle.id}", "elixir")
    assert has_element?(view, "#c-#{cycle.id}", "session demo")
    assert has_element?(view, "#c-#{cycle.id}", "result")
    assert has_element?(view, "#c-#{cycle.id}", "io")
    assert has_element?(view, "#c-#{cycle.id} pre", "stdout from eval")

    highlight_count =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#c-#{cycle.id} .froth-highlight")
      |> length()

    assert highlight_count == 4
  end

  defp unique_chat_id do
    9_000_000_000 + System.unique_integer([:positive])
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

  defp ensure_username(user_id, first_name, session_id)
       when is_integer(user_id) and is_binary(first_name) and is_binary(session_id) do
    %Username{}
    |> Username.changeset(%{
      user_id: user_id,
      first_name: first_name,
      label: "@#{String.downcase(first_name)}",
      source_session_id: session_id
    })
    |> Repo.insert(
      on_conflict: [
        set: [
          first_name: first_name,
          label: "@#{String.downcase(first_name)}",
          source_session_id: session_id,
          updated_at: DateTime.utc_now()
        ]
      ],
      conflict_target: :user_id
    )
  end

  defp insert_telegram_message(session_id, chat_id, message_id, sender_id, date, text) do
    raw = %{
      "id" => message_id,
      "chat_id" => chat_id,
      "date" => date,
      "sender_id" => %{"user_id" => sender_id},
      "content" => %{
        "@type" => "messageText",
        "text" => %{"text" => text}
      }
    }

    %TelegramMessage{}
    |> TelegramMessage.changeset(%{
      telegram_session_id: session_id,
      chat_id: chat_id,
      message_id: message_id,
      sender_id: sender_id,
      date: date,
      raw: raw
    })
    |> Repo.insert!()
  end
end
