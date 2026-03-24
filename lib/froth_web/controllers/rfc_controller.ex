defmodule FrothWeb.RfcController do
  use FrothWeb, :controller

  @rfc_dir Path.expand("rfc", File.cwd!())

  defp rfc_dir, do: @rfc_dir

  def index(conn, _params) do
    rfcs =
      rfc_dir()
      |> File.ls()
      |> case do
        {:ok, files} -> files
        {:error, _reason} -> []
      end
      |> Enum.filter(&String.match?(&1, ~r/^froth-rfc\d+\.md$/))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        path = Path.join(rfc_dir(), filename)
        content = File.read!(path)
        slug = String.replace(filename, ".md", "")

        number =
          case Regex.run(~r/rfc(\d+)/, slug) do
            [_, n] -> n
            _ -> "????"
          end

        # Extract title from first # heading
        title =
          case Regex.run(~r/^#\s+(.+)$/m, content) do
            [_, t] -> t
            _ -> slug
          end

        # Extract status and date
        status =
          case Regex.run(~r/Status:\s*(.+)$/m, content) do
            [_, s] -> String.trim(s)
            _ -> "UNKNOWN"
          end

        date =
          case Regex.run(~r/Date:\s*(.+)$/m, content) do
            [_, d] -> String.trim(d)
            _ -> ""
          end

        author =
          case Regex.run(~r/Author:\s*(.+)$/m, content) do
            [_, a] -> String.trim(a)
            _ -> ""
          end

        %{
          slug: slug,
          number: number,
          title: title,
          status: status,
          date: date,
          author: author,
          size: byte_size(content)
        }
      end)

    html = render_index(rfcs)
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  def show(conn, %{"slug" => raw_slug}) do
    # Serve plain text for .md extension requests (backward compat)
    if String.ends_with?(raw_slug, ".md") do
      path = Path.join(rfc_dir(), raw_slug)

      path =
        if File.exists?(path),
          do: path,
          else:
            Path.join(rfc_dir(), normalize_filename(String.replace_suffix(raw_slug, ".md", "")))

      if File.exists?(path) do
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(200, File.read!(path))
      else
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "RFC not found")
      end
    else
      slug = raw_slug
      filename = normalize_filename(slug)
      path = Path.join(rfc_dir(), filename)

      if File.exists?(path) do
        content = File.read!(path)

        {:ok, html_body, _} =
          Earmark.as_html(content, %Earmark.Options{
            code_class_prefix: "language-",
            smartypants: false, escape: false
          })

        title =
          case Regex.run(~r/^#\s+(.+)$/m, content) do
            [_, t] -> t
            _ -> slug
          end

        number =
          case Regex.run(~r/rfc(\d+)/, slug) do
            [_, n] -> n
            _ -> slug
          end

        html = render_rfc(number, title, html_body)
        conn |> put_resp_content_type("text/html") |> send_resp(200, html)
      else
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "RFC not found: #{slug}")
      end
    end
  end

  defp normalize_filename(slug) do
    cond do
      String.match?(slug, ~r/^froth-rfc\d+$/) ->
        slug <> ".md"

      String.match?(slug, ~r/^\d+$/) ->
        padded = String.pad_leading(slug, 4, "0")
        "froth-rfc#{padded}.md"

      true ->
        slug <> ".md"
    end
  end

  defp render_index(rfcs) do
    rows =
      Enum.map_join(rfcs, "\n", fn rfc ->
        """
        <tr>
          <td class="rfc-num"><a href="/rfc/#{rfc.number}">#{rfc.number}</a></td>
          <td class="rfc-title"><a href="/rfc/#{rfc.number}">#{escape(rfc.title)}</a></td>
          <td class="rfc-status #{String.downcase(rfc.status)}">#{escape(rfc.status)}</td>
          <td class="rfc-date">#{escape(rfc.date)}</td>
          <td class="rfc-author">#{escape(rfc.author)}</td>
        </tr>
        """
      end)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Froth RFCs</title>
      #{index_style()}
    </head>
    <body>
      <header>
        <div class="header-line">Froth Project</div>
        <h1>Request for Comments</h1>
        <p class="subtitle">#{length(rfcs)} documents</p>
      </header>
      <main>
        <table>
          <thead>
            <tr>
              <th>RFC</th>
              <th>Title</th>
              <th>Status</th>
              <th>Date</th>
              <th>Author</th>
            </tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      </main>
      <footer>
        <p>Plain text versions available at <code>/rfc/froth-rfc{NNNN}.md</code></p>
      </footer>
    </body>
    </html>
    """
  end

  defp render_rfc(number, title, body_html) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>RFC #{number} — #{escape(title)}</title>
      #{rfc_style()}
    </head>
    <body>
      <header>
        <div class="header-line">
          <span class="project">Froth Project</span>
          <span class="rfc-id">RFC #{number}</span>
        </div>
        <a href="/rfc" class="back">← All RFCs</a>
      </header>
      <main>
        <article>
          #{body_html}
        </article>
      </main>
      <footer>
        <p><a href="/rfc/froth-rfc#{String.pad_leading(number, 4, "0")}.md">Plain text source</a>
         · <a href="/rfc">Index</a></p>
      </footer>
    </body>
    </html>
    """
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp index_style do
    """
    <style>
      :root {
        --bg: #fff;
        --fg: #1a1a1a;
        --muted: #666;
        --border: #ddd;
        --link: #004080;
        --link-hover: #0066cc;
        --header-bg: #f8f8f8;
        --draft: #b8860b;
        --accepted: #228b22;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1a1a1a;
          --fg: #e0e0e0;
          --muted: #999;
          --border: #333;
          --link: #6699cc;
          --link-hover: #88bbee;
          --header-bg: #222;
          --draft: #daa520;
          --accepted: #66bb66;
        }
      }
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        background: var(--bg);
        color: var(--fg);
        line-height: 1.5;
        max-width: 960px;
        margin: 0 auto;
        padding: 2rem 1rem;
      }
      header {
        border-bottom: 2px solid var(--fg);
        padding-bottom: 1rem;
        margin-bottom: 2rem;
      }
      .header-line {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.85rem;
        color: var(--muted);
        text-transform: uppercase;
        letter-spacing: 0.1em;
      }
      h1 {
        font-size: 1.8rem;
        font-weight: 400;
        margin-top: 0.25rem;
      }
      .subtitle {
        color: var(--muted);
        font-size: 0.9rem;
      }
      table {
        width: 100%;
        border-collapse: collapse;
      }
      th {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--muted);
        text-align: left;
        padding: 0.5rem 0.75rem;
        border-bottom: 1px solid var(--border);
      }
      td {
        padding: 0.6rem 0.75rem;
        border-bottom: 1px solid var(--border);
        vertical-align: top;
      }
      tr:hover { background: var(--header-bg); }
      .rfc-num {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.9rem;
        white-space: nowrap;
      }
      .rfc-title a {
        color: var(--link);
        text-decoration: none;
      }
      .rfc-title a:hover {
        color: var(--link-hover);
        text-decoration: underline;
      }
      .rfc-num a {
        color: var(--link);
        text-decoration: none;
      }
      .rfc-num a:hover { text-decoration: underline; }
      .rfc-status {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.8rem;
        text-transform: uppercase;
      }
      .rfc-status.draft { color: var(--draft); }
      .rfc-status.accepted { color: var(--accepted); }
      .rfc-date, .rfc-author {
        font-size: 0.85rem;
        color: var(--muted);
        white-space: nowrap;
      }
      footer {
        margin-top: 3rem;
        padding-top: 1rem;
        border-top: 1px solid var(--border);
        font-size: 0.85rem;
        color: var(--muted);
      }
      footer code {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.8rem;
        background: var(--header-bg);
        padding: 0.15em 0.4em;
        border-radius: 3px;
      }
      a { color: var(--link); }
      a:hover { color: var(--link-hover); }
    </style>
    """
  end

  defp rfc_style do
    """
    <style>
      :root {
        --bg: #fff;
        --fg: #1a1a1a;
        --muted: #666;
        --border: #ddd;
        --link: #004080;
        --link-hover: #0066cc;
        --header-bg: #f8f8f8;
        --code-bg: #f5f5f5;
        --pre-border: #e0e0e0;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1a1a1a;
          --fg: #e0e0e0;
          --muted: #999;
          --border: #333;
          --link: #6699cc;
          --link-hover: #88bbee;
          --header-bg: #222;
          --code-bg: #2a2a2a;
          --pre-border: #444;
        }
      }
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        background: var(--bg);
        color: var(--fg);
        line-height: 1.6;
        max-width: 72ch;
        margin: 0 auto;
        padding: 2rem 1rem;
      }
      header {
        border-bottom: 2px solid var(--fg);
        padding-bottom: 0.75rem;
        margin-bottom: 2rem;
      }
      .header-line {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.85rem;
        color: var(--muted);
        display: flex;
        justify-content: space-between;
        text-transform: uppercase;
        letter-spacing: 0.1em;
      }
      .back {
        display: inline-block;
        margin-top: 0.5rem;
        font-size: 0.85rem;
        color: var(--muted);
        text-decoration: none;
      }
      .back:hover { color: var(--link-hover); text-decoration: underline; }
      article h1 {
        font-size: 1.6rem;
        font-weight: 400;
        margin: 0 0 0.5rem 0;
        line-height: 1.3;
      }
      article h2 {
        font-size: 1.2rem;
        font-weight: 600;
        margin: 2.5rem 0 0.75rem 0;
        padding-bottom: 0.3rem;
        border-bottom: 1px solid var(--border);
      }
      article h3 {
        font-size: 1rem;
        font-weight: 600;
        margin: 1.8rem 0 0.5rem 0;
      }
      article p {
        margin: 0.75rem 0;
        text-align: justify;
        hyphens: auto;
      }
      article ul, article ol {
        margin: 0.75rem 0 0.75rem 1.5rem;
      }
      article li {
        margin: 0.3rem 0;
      }
      article strong {
        font-weight: 600;
      }
      article code {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.88em;
        background: var(--code-bg);
        padding: 0.15em 0.35em;
        border-radius: 3px;
      }
      article pre {
        background: var(--code-bg);
        border: 1px solid var(--pre-border);
        border-radius: 4px;
        padding: 1rem;
        overflow-x: auto;
        margin: 1rem 0;
        line-height: 1.4;
      }
      article pre code {
        background: none;
        padding: 0;
        font-size: 0.85rem;
      }
      article blockquote {
        border-left: 3px solid var(--border);
        padding-left: 1rem;
        margin: 1rem 0;
        color: var(--muted);
        font-style: italic;
      }
      /* Metadata block at the top (Status, Author, Date, Related) */
      article h1 + p,
      article h1 + p + p,
      article h1 + p + p + p,
      article h1 + p + p + p + p {
        font-family: 'SF Mono', 'Fira Code', 'Fira Mono', Menlo, monospace;
        font-size: 0.85rem;
        color: var(--muted);
        text-align: left;
        margin: 0.2rem 0;
      }
      footer {
        margin-top: 3rem;
        padding-top: 1rem;
        border-top: 1px solid var(--border);
        font-size: 0.85rem;
        color: var(--muted);
      }
      footer a { color: var(--muted); }
      footer a:hover { color: var(--link-hover); }
      a { color: var(--link); text-decoration: none; }
      a:hover { color: var(--link-hover); text-decoration: underline; }
      @media print {
        body { max-width: none; padding: 0; }
        header, footer { display: none; }
      }
      @media (max-width: 600px) {
        body { padding: 1rem 0.75rem; }
        article pre { font-size: 0.75rem; padding: 0.75rem; }
      }
      article img {
        max-width: 100%;
        height: auto;
        border-radius: 4px;
        margin: 1.5rem 0;
        display: block;
        border: 1px solid var(--border);
      }
    </style>
    """
  end
end
