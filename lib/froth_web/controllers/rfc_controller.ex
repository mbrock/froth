defmodule FrothWeb.RfcController do
  use FrothWeb, :controller

  @rfc_dir Path.expand("rfc", File.cwd!())
  @xsl_path Path.join(@rfc_dir, "rfc.xsl")

  defp rfc_dir, do: @rfc_dir

  def index(conn, _params) do
    rfcs =
      rfc_dir()
      |> File.ls!()
      |> Enum.filter(&String.match?(&1, ~r/^froth-rfc\d+\.xml$/))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        path = Path.join(rfc_dir(), filename)
        content = File.read!(path)

        number = case Regex.run(~r/rfc(\d+)/, filename) do
          [_, n] -> n
          _ -> "????"
        end

        title = case Regex.run(~r/<title>(.+?)<\/title>/, content) do
          [_, t] -> t
          _ -> filename
        end

        status = case Regex.run(~r/<status>(.+?)<\/status>/, content) do
          [_, s] -> s
          _ -> "UNKNOWN"
        end

        date = case Regex.run(~r/<date>(.+?)<\/date>/, content) do
          [_, d] -> d
          _ -> ""
        end

        author = case Regex.run(~r/<author>(.+?)<\/author>/, content) do
          [_, a] -> a
          _ -> ""
        end

        %{number: number, title: title, status: status, date: date, author: author}
      end)

    html = render_index(rfcs)
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  def show(conn, %{"slug" => raw_slug}) do
    cond do
      # Serve raw XML source
      String.ends_with?(raw_slug, ".xml") ->
        path = Path.join(rfc_dir(), raw_slug)
        if File.exists?(path) do
          conn
          |> put_resp_content_type("application/xml; charset=utf-8")
          |> send_resp(200, File.read!(path))
        else
          conn |> send_resp(404, "Not found")
        end

      # Serve raw markdown source (backward compat)
      String.ends_with?(raw_slug, ".md") ->
        path = Path.join(rfc_dir(), raw_slug)
        if File.exists?(path) do
          conn
          |> put_resp_content_type("text/plain; charset=utf-8")
          |> send_resp(200, File.read!(path))
        else
          conn |> send_resp(404, "Not found")
        end

      # Serve XSL stylesheet
      raw_slug == "rfc.xsl" ->
        conn
        |> put_resp_content_type("text/xsl; charset=utf-8")
        |> send_resp(200, File.read!(@xsl_path))

      # Serve schema
      raw_slug == "schema.xsd" ->
        path = Path.join(rfc_dir(), "schema.xsd")
        conn
        |> put_resp_content_type("application/xml; charset=utf-8")
        |> send_resp(200, File.read!(path))

      # Default: server-side XSLT transform to HTML
      true ->
        xml_path = resolve_xml(raw_slug)
        if xml_path && File.exists?(xml_path) do
          case xslt_transform(xml_path) do
            {:ok, html} ->
              conn |> put_resp_content_type("text/html") |> send_resp(200, html)
            {:error, reason} ->
              conn |> send_resp(500, "XSLT error: #{reason}")
          end
        else
          # Fall back to markdown
          md_path = resolve_md(raw_slug)
          if md_path && File.exists?(md_path) do
            serve_markdown(conn, md_path, raw_slug)
          else
            conn |> send_resp(404, "RFC not found: #{raw_slug}")
          end
        end
    end
  end

  defp resolve_xml(slug) do
    cond do
      String.match?(slug, ~r/^\d+$/) ->
        padded = String.pad_leading(slug, 4, "0")
        Path.join(rfc_dir(), "froth-rfc#{padded}.xml")
      String.match?(slug, ~r/^froth-rfc\d+$/) ->
        Path.join(rfc_dir(), slug <> ".xml")
      true ->
        nil
    end
  end

  defp resolve_md(slug) do
    cond do
      String.match?(slug, ~r/^\d+$/) ->
        padded = String.pad_leading(slug, 4, "0")
        Path.join(rfc_dir(), "froth-rfc#{padded}.md")
      String.match?(slug, ~r/^froth-rfc\d+$/) ->
        Path.join(rfc_dir(), slug <> ".md")
      true ->
        nil
    end
  end

  defp xslt_transform(xml_path) do
    case System.cmd("xsltproc", [@xsl_path, xml_path], stderr_to_stdout: true) do
      {html, 0} -> {:ok, html}
      {err, _} -> {:error, err}
    end
  end

  defp serve_markdown(conn, path, slug) do
    content = File.read!(path)
    {:ok, html_body, _} = Earmark.as_html(content, %Earmark.Options{
      code_class_prefix: "language-",
      smartypants: false,
      escape: false
    })
    title = case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, t] -> t
      _ -> slug
    end
    number = case Regex.run(~r/rfc(\d+)/, slug) do
      [_, n] -> n
      _ -> slug
    end
    html = render_rfc_markdown(number, title, html_body)
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp render_rfc_markdown(number, title, body_html) do
    """
    <!DOCTYPE html>
    <html lang="en"><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>RFC #{escape(number)} — #{escape(title)}</title>
    </head><body>
      <p><a href="/rfc">← All RFCs</a></p>
      <article>#{body_html}</article>
      <p><em>Rendered from markdown (no XML source available)</em></p>
    </body></html>
    """
  end

  defp render_index(rfcs) do
    rows = Enum.map_join(rfcs, "\n", fn rfc ->
      """
      <tr>
        <td class="rfc-num"><a href="/rfc/#{rfc.number}">#{escape(rfc.number)}</a></td>
        <td class="rfc-title"><a href="/rfc/#{rfc.number}">#{escape(rfc.title)}</a></td>
        <td class="rfc-status">#{escape(rfc.status)}</td>
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
      <style>
        :root { --bg: #fff; --fg: #1a1a1a; --muted: #666; --border: #ddd; --link: #004080; }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #1a1a1a; --fg: #e0e0e0; --muted: #999; --border: #333; --link: #6699cc; }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: 'Iowan Old Style', Palatino, Georgia, serif;
          background: var(--bg); color: var(--fg);
          max-width: 60em; margin: 0 auto; padding: 2em 1.5em;
        }
        h1 { font-size: 1.4em; margin-bottom: 1em; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 0.5em 0.8em; text-align: left; border-bottom: 1px solid var(--border); }
        th { font-size: 0.85em; color: var(--muted); font-weight: normal; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .rfc-num { font-family: monospace; white-space: nowrap; }
        .rfc-status { font-variant: small-caps; font-size: 0.9em; }
        .rfc-date { white-space: nowrap; font-size: 0.9em; color: var(--muted); }
        .rfc-author { font-size: 0.9em; color: var(--muted); }
        footer { margin-top: 2em; font-size: 0.85em; color: var(--muted); }
        @media (max-width: 600px) { td:nth-child(4), td:nth-child(5), th:nth-child(4), th:nth-child(5) { display: none; } }
      </style>
    </head>
    <body>
      <h1>Froth RFCs</h1>
      <table>
        <thead><tr><th>RFC</th><th>Title</th><th>Status</th><th>Date</th><th>Author</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      <footer>
        <p>XML source: <code>/rfc/froth-rfc{NNNN}.xml</code> · Schema: <a href="/rfc/schema.xsd">schema.xsd</a> · Stylesheet: <a href="/rfc/rfc.xsl">rfc.xsl</a></p>
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
end
