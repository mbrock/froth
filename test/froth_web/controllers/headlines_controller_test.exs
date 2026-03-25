defmodule FrothWeb.HeadlinesControllerTest do
  use FrothWeb.ConnCase, async: false

  alias Froth.{ChatSummary, Event, Repo}

  test "GET /froth/headlines renders the ledger as a normal HTML page", %{conn: conn} do
    chat_id = -1_003_690_254_489

    insert_summary(chat_id, ~D[2026-03-21], "The cave manifesto got retyped.")
    insert_summary(chat_id, ~D[2026-03-22], "Cherry theory took over the night.")

    Repo.insert!(%Event{
      event: "froth.headlines.registered",
      measurements: %{"count" => 2},
      metadata: %{
        "chat_id" => Integer.to_string(chat_id),
        "date" => "2026-03-22",
        "headlines" => [
          %{
            "emoji" => "🔥",
            "title" => "Cherry Theory Takes Over",
            "sentence" =>
              "A late-night run turned the cherry theory into the day's dominant story.",
            "from_time" => "2026-03-22T16:00:00Z",
            "to_time" => "2026-03-22T23:59:00Z"
          },
          %{
            "emoji" => "🧱",
            "title" => "Old Manifestos Refuse to Die",
            "sentence" =>
              "New formats kept landing while the cave manifesto kept clawing back into view.",
            "from_time" => "2026-03-22T18:00:00Z",
            "to_time" => "2026-03-22T23:30:00Z"
          }
        ]
      }
    })

    conn = get(conn, ~p"/froth/headlines")
    html = html_response(conn, 200)
    {:ok, document} = Floki.parse_document(html)

    assert Floki.find(document, "[data-phx-main]") == []
    assert Floki.find(document, "#headlines-brutalist-view") != []
    assert Floki.find(document, "#month-2026-03") != []
    assert html =~ "1 / 2"
    assert html =~ "2026-03-21"
    assert html =~ "Cherry Theory Takes Over"
    assert html =~ "16:00-23:59 UTC"
    assert html =~ "Old Manifestos Refuse to Die"
  end

  test "GET /froth/headlines respects the requested chat id", %{conn: conn} do
    first_chat_id = -1_001_111_111_111
    second_chat_id = -1_002_222_222_222

    insert_summary(first_chat_id, ~D[2026-03-18], "First chat summary.")
    insert_summary(second_chat_id, ~D[2026-03-19], "Second chat summary.")

    Repo.insert!(%Event{
      event: "froth.headlines.registered",
      measurements: %{"count" => 1},
      metadata: %{
        "chat_id" => Integer.to_string(first_chat_id),
        "date" => "2026-03-18",
        "headlines" => [
          %{
            "emoji" => "🎙️",
            "title" => "Nikolai Speaks Again",
            "sentence" => "The first chat got the microphone back.",
            "from_time" => "2026-03-18T00:00:00Z",
            "to_time" => "2026-03-18T08:00:00Z"
          }
        ]
      }
    })

    Repo.insert!(%Event{
      event: "froth.headlines.registered",
      measurements: %{"count" => 1},
      metadata: %{
        "chat_id" => Integer.to_string(second_chat_id),
        "date" => "2026-03-19",
        "headlines" => [
          %{
            "emoji" => "🎧",
            "title" => "Podcast Archive Goes Live",
            "sentence" => "The second chat launched the archive.",
            "from_time" => "2026-03-19T00:00:00Z",
            "to_time" => "2026-03-19T08:00:00Z"
          }
        ]
      }
    })

    conn = get(conn, ~p"/froth/headlines?chat_id=#{second_chat_id}")
    html = html_response(conn, 200)
    {:ok, document} = Floki.parse_document(html)

    assert html =~ Integer.to_string(second_chat_id)
    assert html =~ "Podcast Archive Goes Live"
    refute html =~ "Nikolai Speaks Again"

    assert Floki.find(document, ~s(a[href="/froth/headlines?chat_id=#{first_chat_id}"])) != []
    assert Floki.find(document, ~s(a[href="/froth/headlines?chat_id=#{second_chat_id}"])) != []
  end

  defp insert_summary(chat_id, %Date{} = date, summary_text) when is_integer(chat_id) do
    start_at = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_at = DateTime.add(start_at, 86_400, :second)

    Repo.insert!(%ChatSummary{
      chat_id: chat_id,
      from_date: DateTime.to_unix(start_at),
      to_date: DateTime.to_unix(end_at),
      agent: "test-agent",
      summary_text: summary_text,
      message_count: 3,
      metadata: %{}
    })
  end
end
