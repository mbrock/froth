defmodule FrothWeb.SummariesControllerTest do
  use FrothWeb.ConnCase, async: true

  alias Froth.ChatSummary
  alias Froth.Repo

  @chat_id -1_003_690_254_489

  test "GET /froth/summaries renders newest summaries first", %{conn: conn} do
    insert_summary(~D[2026-03-07], "March 7 summary")
    insert_summary(~D[2026-03-08], "March 8 summary")

    conn = get(conn, ~p"/froth/summaries")
    html = html_response(conn, 200)
    {:ok, document} = Floki.parse_document(html)

    headings =
      document
      |> Floki.find("article h2")
      |> Enum.map(&Floki.text/1)

    assert headings == [
             format_heading(~D[2026-03-08]),
             format_heading(~D[2026-03-07])
           ]
  end

  defp insert_summary(%Date{} = date, summary_text) do
    Repo.insert!(
      ChatSummary.changeset(%ChatSummary{}, %{
        chat_id: @chat_id,
        from_date: day_start_unix(date),
        to_date: day_start_unix(Date.add(date, 1)),
        agent: "claude",
        summary_text: summary_text,
        message_count: 2
      })
    )
  end

  defp day_start_unix(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp format_heading(%Date{} = date) do
    Calendar.strftime(date, "%A, %B %-d, %Y")
  end
end
