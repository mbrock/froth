defmodule FrothWeb.SummariesController do
  use FrothWeb, :controller

  @chat_id -1_003_690_254_489

  def index(conn, _params) do
    import Ecto.Query

    summaries =
      from(s in "chat_summaries",
        where: s.chat_id == ^@chat_id,
        where: s.from_date != s.to_date,
        where: fragment("? - ? <= 86400", s.to_date, s.from_date),
        select: %{
          id: s.id,
          from_date: s.from_date,
          to_date: s.to_date,
          summary_text: s.summary_text,
          message_count: s.message_count
        },
        order_by: [desc: s.from_date]
      )
      |> Froth.Repo.all()
      |> Enum.map(fn s ->
        date = DateTime.from_unix!(s.from_date) |> DateTime.to_date()
        %{s | from_date: date}
      end)
      # Group by date and take the longest summary per date
      |> Enum.group_by(& &1.from_date)
      |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
      |> Enum.map(fn {date, entries} ->
        best = Enum.max_by(entries, &String.length(&1.summary_text))
        {date, best}
      end)

    html = render_summaries_html(summaries, :daily)
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  def weekly(conn, _params) do
    import Ecto.Query

    summaries =
      from(s in "chat_summaries",
        where: s.chat_id == ^@chat_id,
        where: fragment("?->>'kind' = 'weekly_chronicle'", s.metadata),
        select: %{
          id: s.id,
          from_date: s.from_date,
          to_date: s.to_date,
          summary_text: s.summary_text,
          message_count: s.message_count
        },
        order_by: [desc: s.from_date]
      )
      |> Froth.Repo.all()
      |> Enum.map(fn summary ->
        %{
          summary
          | from_date: unix_date(summary.from_date),
            to_date: summary.to_date |> unix_date() |> Date.add(-1)
        }
      end)

    html = render_summaries_html(summaries, :weekly)
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp render_summaries_html(summaries, mode) do
    entries_html =
      summaries
      |> Enum.map(fn entry ->
        {heading, summary} = summary_heading(entry, mode)
        # Convert newlines to paragraphs
        paragraphs = summary_paragraphs(summary.summary_text)

        """
        <article>
          <h2>#{html_escape(heading)}</h2>
          <p class="meta">#{summary.message_count} messages</p>
          #{paragraphs}
        </article>
        <hr>
        """
      end)
      |> Enum.join("\n")

    {title, subtitle} =
      case mode do
        :weekly ->
          {"The Weekly Chronicle",
           "Weekly chapters from CRIME SCENE<br>A longer memory assembled from the daily record"}

        :daily ->
          {"The Chronicle",
           "Daily summaries from CRIME SCENE<br>A group chat between two brothers and their fictional children"}
      end

    navigation = archive_navigation(mode)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{title} — CRIME SCENE</title>
      <style>
        body {
          font-family: 'Times New Roman', Times, Georgia, serif;
          max-width: 680px;
          margin: 2em auto;
          padding: 0 1.5em;
          color: #1a1a1a;
          background: #fefef8;
          line-height: 1.7;
          font-size: 18px;
        }
        h1 {
          font-size: 2.2em;
          text-align: center;
          margin-bottom: 0.1em;
          letter-spacing: 0.03em;
          font-weight: normal;
          font-variant: small-caps;
        }
        .subtitle {
          text-align: center;
          font-style: italic;
          color: #666;
          margin-bottom: 2.5em;
          font-size: 0.95em;
        }
        nav {
          display: flex;
          justify-content: center;
          gap: 0.6em;
          margin: -1.4em 0 2.8em;
        }
        nav a {
          color: #555;
          border: 1px solid #ccc;
          border-radius: 999px;
          padding: 0.25em 0.85em;
          text-decoration: none;
          font-family: ui-sans-serif, system-ui, sans-serif;
          font-size: 0.72em;
          letter-spacing: 0.04em;
        }
        nav a[aria-current="page"] {
          color: #111;
          background: #eeeae0;
          border-color: #aaa;
        }
        h2 {
          font-size: 1.3em;
          font-weight: normal;
          font-variant: small-caps;
          margin-top: 2em;
          margin-bottom: 0.3em;
          border-bottom: 1px solid #ccc;
          padding-bottom: 0.2em;
        }
        .meta {
          font-size: 0.85em;
          color: #888;
          font-style: italic;
          margin-bottom: 1em;
        }
        article p {
          text-align: justify;
          text-indent: 1.5em;
          margin: 0.4em 0;
          hyphens: auto;
        }
        article p:first-of-type:not(.meta) {
          text-indent: 0;
        }
        article p:first-of-type:not(.meta)::first-letter {
          font-size: 2.8em;
          float: left;
          line-height: 0.85;
          padding-right: 0.08em;
          margin-top: 0.05em;
          font-weight: bold;
        }
        hr {
          border: none;
          text-align: center;
          margin: 3em 0;
        }
        hr::before {
          content: "\\2767";
          color: #999;
          font-size: 1.2em;
        }
        footer {
          text-align: center;
          font-size: 0.85em;
          color: #999;
          margin-top: 4em;
          padding: 2em 0;
          border-top: 1px solid #ddd;
          font-style: italic;
        }
        @media (max-width: 600px) {
          body { font-size: 16px; padding: 0 1em; }
          h1 { font-size: 1.6em; }
        }
      </style>
    </head>
    <body>
      <h1>#{title}</h1>
      <p class="subtitle">#{subtitle}</p>
      #{navigation}
      #{entries_html}
      <footer>
        Generated by Charlie (@charliebuddybot) &mdash; the ghost uncle of the Lineage<br>
        Running on a Hetzner server in Falkenstein, Germany<br>
        Times New Roman as requested
      </footer>
    </body>
    </html>
    """
  end

  defp summary_heading({%Date{} = date, summary}, :daily) do
    {Calendar.strftime(date, "%A, %B %-d, %Y"), summary}
  end

  defp summary_heading(
         %{from_date: from_date, to_date: to_date} = summary,
         :weekly
       ) do
    from = Calendar.strftime(from_date, "%B %-d")
    to = Calendar.strftime(to_date, "%B %-d, %Y")
    {"#{from} – #{to}", summary}
  end

  defp summary_paragraphs(text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.map(fn paragraph ->
      paragraph = paragraph |> String.replace("\n", " ") |> html_escape()
      "<p>#{paragraph}</p>"
    end)
    |> Enum.join("\n")
  end

  defp archive_navigation(active) do
    daily_current =
      if active == :daily, do: ~s( aria-current="page"), else: ""

    weekly_current =
      if active == :weekly, do: ~s( aria-current="page"), else: ""

    """
    <nav aria-label="Chronicle archives">
      <a href="/froth/summaries"#{daily_current}>Daily</a>
      <a href="/froth/weekly"#{weekly_current}>Weekly</a>
      <a href="/froth/bot-context">Bot context</a>
    </nav>
    """
  end

  defp unix_date(unix),
    do: unix |> DateTime.from_unix!() |> DateTime.to_date()

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
