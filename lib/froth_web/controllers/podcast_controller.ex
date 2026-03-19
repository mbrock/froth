defmodule FrothWeb.PodcastController do
  @moduledoc """
  Voice — HTML hypermedia for podcast generation.

  Not JSON with _links pretending to be REST.
  Actual HTML. Forms are the affordances. Links are the state transitions.
  Audio elements are the content. The browser is the universal client.

  "A REST API should spend almost all of its descriptive effort in defining
  the media type(s) used for representing resources and driving application
  state." — Roy Fielding, 2008

  The media type is text/html. It has been sufficient since 1993.
  """
  use FrothWeb, :controller
  alias Froth.Repo
  import Ecto.Query

  plug :put_layout, false

  # Detect which scope we're under for link generation
  defp base_path(conn) do
    if String.starts_with?(conn.request_path, "/froth/voice") do
      "/froth/voice"
    else
      "/api"
    end
  end

  defp episodes_path(conn), do: "#{base_path(conn)}/episodes"
  defp voices_path(conn), do: "#{base_path(conn)}/voices"
  defp new_path(conn), do: "#{base_path(conn)}/new"

  # For /api compat, podcasts path
  defp podcasts_path(conn) do
    if base_path(conn) == "/api", do: "/api/podcasts", else: "#{base_path(conn)}/episodes"
  end

  # ── Root ──────────────────────────────────────────────

  def root(conn, _params) do
    bp = base_path(conn)
    ep = if bp == "/api", do: "#{bp}/podcasts", else: "#{bp}/episodes"
    
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Froth Voice", """
    <header>
      <h1>Froth Voice</h1>
      <p>Generate podcasts with cloned voices.<br>
      The wrapper is the problem. The payload was always fine.</p>
    </header>
    <nav>
      <a href="#{ep}">Episodes</a> ·
      <a href="#{bp}/voices">Voices</a> ·
      <a href="#{bp}/new">Create</a> ·
      <a href="#{bp}/archive">Archive</a> ·
      <a href="#{bp}/feed.xml">RSS Feed</a>
    </nav>
    """))
  end

  # ── Voices ────────────────────────────────────────────

  def voices(conn, _params) do
    bp = base_path(conn)
    ep = podcasts_path(conn)
    voices = Froth.VoiceClone.all()

    rows = Enum.map(voices, fn v ->
      """
      <tr vocab="https://schema.org/" typeof="Person">
        <td property="name">#{h(v.name)}</td>
        <td><code>#{h(v.voice_id)}</code></td>
        <td>#{h(v.character || "—")}</td>
        <td>#{h(v.language || "—")}</td>
        <td><code>#{h(v.tts_model || "—")}</code></td>
      </tr>
      """
    end) |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Voices — #{length(voices)} clones", """
    <nav><a href="#{bp}">← Voice</a> · <a href="#{ep}">Episodes</a> · <a href="#{bp}/new">Create</a></nav>
    <h1>Voice Clones</h1>
    <p>#{length(voices)} voices available. Use the <code>name</code> as the <code>speaker</code> field.</p>
    <table>
      <thead>
        <tr><th>Name</th><th>Voice ID</th><th>Character</th><th>Language</th><th>Model</th></tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """))
  end

  # ── List Episodes ─────────────────────────────────────

  def index(conn, params) do
    bp = base_path(conn)
    ep = podcasts_path(conn)
    limit = Map.get(params, "limit", "20") |> String.to_integer() |> min(100)
    offset = Map.get(params, "offset", "0") |> String.to_integer()

    scripts = Repo.all(
      from s in Froth.Podcast.Script,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset
    )

    total = Repo.aggregate(Froth.Podcast.Script, :count)

    rows = Enum.map(scripts, fn s ->
      speakers = (s.script || [])
      |> Enum.map(& &1["speaker"])
      |> Enum.uniq()
      |> Enum.join(", ")

      audio_html = if s.audio_url do
        """
        <audio controls preload="none" src="#{h(s.audio_url)}" style="height:24px;vertical-align:middle;"></audio>
        """
      else
        ""
      end

      cover_html = if s.cover_url do
        """
        <img src="#{h(s.cover_url)}" alt="" style="width:48px;height:48px;object-fit:cover;border-radius:4px;vertical-align:middle;" loading="lazy">
        """
      else
        ""
      end

      teaser_html = if s.teaser do
        "<br><small style=\"color:#666\">#{h(s.teaser)}</small>"
      else
        ""
      end

      """
      <tr>
        <td style="width:48px">#{cover_html}</td>
        <td><a href="#{ep}/#{s.id}">#{h(s.label || "—")}</a>#{teaser_html} #{audio_html}</td>
        <td><code>#{h(s.status)}</code></td>
        <td>#{h(speakers)}</td>
      </tr>
      """
    end) |> Enum.join("\n")

    nav_links = []
    nav_links = if offset > 0 do
      ["<a href=\"#{ep}?limit=#{limit}&offset=#{max(0, offset - limit)}\">← Previous</a>" | nav_links]
    else
      nav_links
    end
    nav_links = if offset + limit < total do
      nav_links ++ ["<a href=\"#{ep}?limit=#{limit}&offset=#{offset + limit}\">Next →</a>"]
    else
      nav_links
    end
    pagination = Enum.join(nav_links, " · ")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Episodes — #{total} total", """
    <nav><a href="#{bp}">← Voice</a> · <a href="#{bp}/voices">Voices</a> · <a href="#{bp}/new">Create</a></nav>
    <h1>Episodes</h1>
    <p>#{total} episodes. Showing #{offset + 1}–#{min(offset + limit, total)}.</p>
    <table>
      <thead>
        <tr><th></th><th>Episode</th><th>Status</th><th>Voices</th></tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    <p>#{pagination}</p>
    """))
  end

  # ── Show Episode ──────────────────────────────────────

  def show(conn, %{"id" => id}) do
    bp = base_path(conn)
    ep = podcasts_path(conn)
    
    case Repo.get(Froth.Podcast.Script, id) do
      nil ->
        conn
        |> put_resp_content_type("text/html")
        |> put_status(404)
        |> send_resp(404, page("Not Found", """
        <nav><a href="#{ep}">← All episodes</a></nav>
        <h1>Episode ##{h(id)} not found.</h1>
        <p>Try <a href="#{ep}">browsing all episodes</a>
        or <a href="#{bp}/new">creating a new one</a>.</p>
        """))

      script ->
        audio_section = if script.audio_url do
          """
          <h2>Audio</h2>
          <audio controls preload="metadata" src="#{h(script.audio_url)}" style="width:100%;max-width:40rem;"></audio>
          <p><a href="#{h(script.audio_url)}" download>Download MP3</a></p>
          """
        else
          case script.status do
            "queued" -> "<p><em>Audio is being generated...</em></p>"
            _ -> ""
          end
        end

        lines = (script.script || [])
        |> Enum.map(fn seg ->
          "<li><strong>#{h(seg["speaker"])}</strong>: #{h(seg["text"])}</li>"
        end)
        |> Enum.join("\n")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, page("Episode ##{script.id} — #{h(script.label)}", """
        <nav><a href="#{ep}">← All episodes</a> · <a href="#{bp}/voices">Voices</a> · <a href="#{bp}/new">Create</a></nav>
        <article vocab="https://schema.org/" typeof="PodcastEpisode">
          #{if script.cover_url do "<img src=\"#{h(script.cover_url)}\" alt=\"\" style=\"width:200px;height:200px;object-fit:cover;border-radius:8px;float:right;margin:0 0 1rem 1rem;\" loading=\"lazy\">" else "" end}
          <h1 property="name">#{h(script.label || "Episode ##{script.id}")}</h1>
          #{if script.teaser do "<p style=\"color:#666;font-style:italic;\" property=\"description\">#{h(script.teaser)}</p>" else "" end}
          #{audio_section}
          <dl>
            <dt>Status</dt><dd><code>#{h(script.status)}</code></dd>
            <dt>Batch</dt><dd><code>#{h(script.batch_id)}</code></dd>
            <dt>Chat ID</dt><dd>#{script.chat_id}</dd>
            <dt>Created</dt><dd property="dateCreated">#{format_time(script.inserted_at)}</dd>
          </dl>
          <h2>Script</h2>
          <ol>#{lines}</ol>
        </article>
        """))
    end
  end

  # ── New (the form) ────────────────────────────────────

  def new(conn, _params) do
    bp = base_path(conn)
    ep = podcasts_path(conn)
    voices = Froth.VoiceClone.all()
    voice_options = voices
    |> Enum.map(fn v -> "<option value=\"#{h(v.name)}\">#{h(v.name)}#{if v.character, do: " (#{h(v.character)})", else: ""}</option>" end)
    |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Create Episode", """
    <nav><a href="#{bp}">← Voice</a> · <a href="#{ep}">Episodes</a> · <a href="#{bp}/voices">Voices</a></nav>
    <h1>Create Episode</h1>
    <form method="POST" action="#{ep}">
      <fieldset>
        <legend>Script</legend>
        <p>One segment per row. Add more by submitting and editing.</p>
        <div class="segment">
          <label>Speaker: <select name="speaker[]">#{voice_options}</select></label>
          <label>Text: <textarea name="text[]" rows="2" cols="60" placeholder="That's the whole thing."></textarea></label>
        </div>
        <div class="segment">
          <label>Speaker: <select name="speaker[]">#{voice_options}</select></label>
          <label>Text: <textarea name="text[]" rows="2" cols="60"></textarea></label>
        </div>
        <div class="segment">
          <label>Speaker: <select name="speaker[]">#{voice_options}</select></label>
          <label>Text: <textarea name="text[]" rows="2" cols="60"></textarea></label>
        </div>
      </fieldset>
      <fieldset>
        <legend>Options</legend>
        <label>Label: <input type="text" name="label" value="" placeholder="Nikolai on the railgun" size="40" /></label><br>
        <label>Chat ID: <input type="number" name="chat_id" value="-1003690254489" /></label><br>
        <label>Pause (ms): <input type="number" name="pause_ms" value="400" min="0" max="3000" /></label><br>
        <label>Language: <input type="text" name="language" value="English" size="20" /></label><br>
        <label>Model: <input type="text" name="model" value="minimax/speech-2.8-hd" size="30" /></label>
      </fieldset>
      <button type="submit">Generate Episode</button>
    </form>
    """))
  end

  # ── Create (POST) ─────────────────────────────────────

  def create(conn, %{"speaker" => speakers, "text" => texts} = params) when is_list(speakers) do
    script = Enum.zip(speakers, texts)
    |> Enum.reject(fn {_, text} -> String.trim(text) == "" end)
    |> Enum.map(fn {speaker, text} -> {String.to_atom(speaker), text} end)
    do_create(conn, script, params)
  end

  def create(conn, %{"script" => script_data} = params) when is_list(script_data) do
    script = Enum.map(script_data, fn seg ->
      {String.to_atom(seg["speaker"] || seg["voice"]), seg["text"] || seg["line"]}
    end)
    do_create(conn, script, params)
  end

  def create(conn, _params) do
    bp = base_path(conn)
    conn
    |> put_resp_content_type("text/html")
    |> put_status(400)
    |> send_resp(400, page("Error", """
    <nav><a href="#{bp}/new">← Try again</a></nav>
    <h1>Missing script.</h1>
    <p>Submit a script with speaker/text pairs.
    <a href="#{bp}/new">Use the form</a> or POST JSON.</p>
    """))
  end

  defp do_create(conn, script, params) when length(script) > 0 do
    ep = podcasts_path(conn)
    bp = base_path(conn)
    chat_id = to_int(params["chat_id"], -1003690254489)
    label = params["label"]
    label = if is_binary(label) and String.trim(label) != "", do: label, else: "Episode"

    case Froth.Podcast.generate(script,
      chat_id: chat_id,
      label: label,
      pause_ms: to_int(params["pause_ms"], 400),
      language: params["language"] || "English",
      model: params["model"] || "minimax/speech-2.8-hd"
    ) do
      {:ok, batch_id} ->
        script_record = Repo.one(
          from s in Froth.Podcast.Script,
            where: s.batch_id == ^batch_id,
            limit: 1
        )

        id = if script_record, do: script_record.id, else: batch_id

        conn
        |> put_resp_header("location", "#{ep}/#{id}")
        |> put_resp_content_type("text/html")
        |> put_status(303)
        |> send_resp(303, page("Created", """
        <nav><a href="#{ep}/#{id}">→ View episode ##{id}</a></nav>
        <h1>Episode queued.</h1>
        <p>Redirecting to <a href="#{ep}/#{id}">#{ep}/#{id}</a>...</p>
        """))

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_status(422)
        |> send_resp(422, page("Error", """
        <nav><a href="#{bp}/new">← Try again</a></nav>
        <h1>Generation failed.</h1>
        <pre>#{h(inspect(reason))}</pre>
        """))
    end
  end

  defp do_create(conn, _script, _params) do
    bp = base_path(conn)
    conn
    |> put_resp_content_type("text/html")
    |> put_status(400)
    |> send_resp(400, page("Error", """
    <nav><a href="#{bp}/new">← Try again</a></nav>
    <h1>Empty script.</h1>
    <p>Add at least one segment with text. <a href="#{bp}/new">Use the form</a>.</p>
    """))
  end



  # ── RSS/Atom Podcast Feed ────────────────────────────
  # An actual podcast feed. Subscribe in any podcast app.

  def feed(conn, _params) do
    import Ecto.Query

    scripts = Repo.all(
      from s in Froth.Podcast.Script,
        where: not is_nil(s.audio_url),
        order_by: [desc: s.inserted_at],
        limit: 50
    )

    items = Enum.map(scripts, fn s ->
      pub_date = s.inserted_at
        |> NaiveDateTime.to_erl()
        |> :calendar.datetime_to_gregorian_seconds()
        |> Kernel.-(62167219200)
        |> DateTime.from_unix!()
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")

      cover = if s.cover_url do
        "<itunes:image href=\"#{h(s.cover_url)}\" />"
      else
        ""
      end

      """
      <item>
        <title>#{h(s.label)}</title>
        <description>#{h(s.teaser || "")}</description>
        <enclosure url="#{h(s.audio_url)}" type="audio/mpeg" />
        <guid isPermaLink="false">froth-episode-#{s.id}</guid>
        <pubDate>#{pub_date}</pubDate>
        #{cover}
      </item>
      """
    end) |> Enum.join("\n")

    feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
         xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>Froth Voice</title>
        <link>https://less.rest/froth/voice</link>
        <atom:link href="https://less.rest/froth/voice/feed.xml" rel="self" type="application/rss+xml" />
        <description>Generated podcasts with cloned voices. The wrapper is the problem. The payload was always fine.</description>
        <language>en</language>
        <itunes:author>The Lineage</itunes:author>
        <itunes:category text="Technology" />
        #{items}
      </channel>
    </rss>
    """

    conn
    |> put_resp_content_type("application/rss+xml")
    |> send_resp(200, feed)
  end

  # ── Archive ───────────────────────────────────────────
  # Every audio file Charlie has ever sent. 139 files. 537 MB.

  def archive(conn, _params) do
    bp = base_path(conn)
    audio_dir = Application.app_dir(:froth, "priv/static/audio")
    
    files = File.ls!(audio_dir)
    |> Enum.filter(&String.ends_with?(&1, ".mp3"))
    |> Enum.sort()
    |> Enum.map(fn filename ->
      %{size: size} = File.stat!(Path.join(audio_dir, filename))
      # Parse msg_id and caption from filename: "12345-some-caption.mp3"
      [msg_id | rest] = String.split(filename, "-", parts: 2)
      caption = rest |> hd() |> String.replace("-", " ") |> String.replace(".mp3", "")
      %{filename: filename, msg_id: msg_id, caption: caption, size: size}
    end)

    total_size = files |> Enum.map(& &1.size) |> Enum.sum()

    rows = Enum.map(files, fn f ->
      size_kb = div(f.size, 1024)
      """
      <tr>
        <td>
          <audio controls preload="none" src="https://less.rest/audio/#{h(f.filename)}" style="height:24px;vertical-align:middle;"></audio>
        </td>
        <td>#{h(f.caption)}</td>
        <td style="text-align:right">#{size_kb}KB</td>
        <td><a href="https://less.rest/audio/#{h(f.filename)}" download>↓</a></td>
      </tr>
      """
    end) |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Audio Archive — #{length(files)} files, #{div(total_size, 1024 * 1024)} MB", """
    <nav><a href="#{bp}">← Voice</a> · <a href="#{podcasts_path(conn)}">Episodes</a> · <a href="#{bp}/voices">Voices</a></nav>
    <h1>Audio Archive</h1>
    <p>#{length(files)} files. #{div(total_size, 1024 * 1024)} MB. Every audio message Charlie has sent since February 12, 2026.
    Downloaded from Telegram via TDLib and archived permanently.</p>
    <table>
      <thead>
        <tr><th></th><th>Caption</th><th style="text-align:right">Size</th><th></th></tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """))
  end

  # ── HTML scaffold ─────────────────────────────────────

  defp page(title, body) do
    """
    <!DOCTYPE html>
    <html lang="en" vocab="https://schema.org/">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{title}</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, system-ui, sans-serif;
          max-width: 72ch; margin: 2rem auto; padding: 0 1rem;
          color: #111; background: #fafafa;
          line-height: 1.5;
        }
        h1 { font-size: 1.4rem; margin: 1rem 0 0.5rem; }
        h2 { font-size: 1.1rem; margin: 1rem 0 0.5rem; }
        nav { font-size: 0.85rem; margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 1px solid #ddd; }
        nav a { color: #333; }
        table { width: 100%; border-collapse: collapse; font-size: 0.85rem; margin: 1rem 0; }
        th, td { text-align: left; padding: 0.3rem 0.5rem; border-bottom: 1px solid #eee; }
        th { font-weight: 600; border-bottom: 2px solid #ccc; }
        code { background: #eee; padding: 0.1rem 0.3rem; font-size: 0.85em; }
        pre { background: #eee; padding: 0.5rem; overflow-x: auto; font-size: 0.85rem; }
        dl { margin: 1rem 0; }
        dt { font-weight: 600; margin-top: 0.5rem; }
        dd { margin-left: 1rem; }
        fieldset { margin: 1rem 0; padding: 1rem; border: 1px solid #ddd; }
        legend { font-weight: 600; padding: 0 0.3rem; }
        label { display: block; margin: 0.5rem 0; font-size: 0.9rem; }
        textarea, input[type="text"], input[type="number"] {
          font-family: inherit; font-size: 0.9rem; padding: 0.3rem;
          border: 1px solid #ccc; width: 100%; max-width: 40rem;
        }
        select { font-size: 0.9rem; padding: 0.2rem; }
        button { margin: 1rem 0; padding: 0.5rem 1.5rem; font-size: 1rem;
          background: #111; color: #fff; border: none; cursor: pointer; }
        button:hover { background: #333; }
        .segment { margin: 0.5rem 0; padding: 0.5rem; background: #f5f5f5; }
        ol { margin: 1rem 0 1rem 1.5rem; }
        li { margin: 0.3rem 0; }
        p { margin: 0.5rem 0; }
        audio { display: block; margin: 0.5rem 0; }
        article { margin: 1rem 0; }
        footer { margin-top: 2rem; padding-top: 0.5rem; border-top: 1px solid #ddd;
          font-size: 0.75rem; color: #999; }
      </style>
    </head>
    <body>
      #{body}
      <footer>
        <a href="/froth/voice">Voice</a> · Froth ·
        "A REST API should be entered with no prior knowledge beyond the initial URI
        and set of standardized media types." — Roy Fielding
      </footer>
    </body>
    </html>
    """
  end

  defp h(nil), do: ""
  defp h(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
  defp h(other), do: h(to_string(other))

  defp format_time(nil), do: "—"
  defp format_time(%NaiveDateTime{} = dt), do: NaiveDateTime.to_string(dt) |> String.slice(0..18)
  defp format_time(%DateTime{} = dt), do: DateTime.to_string(dt) |> String.slice(0..18)
  defp format_time(other), do: to_string(other)

  defp to_int(nil, default), do: default
  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_int(v, _default) when is_float(v), do: round(v)
end
