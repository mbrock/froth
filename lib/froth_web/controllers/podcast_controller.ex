defmodule FrothWeb.PodcastController do
  @moduledoc """
  Voice — HTML hypermedia for podcast generation.
  The media type is text/html. It has been sufficient since 1993.
  """
  use FrothWeb, :controller
  alias Froth.Repo
  import Ecto.Query

  plug :put_layout, false

  defp base_path(conn) do
    if String.starts_with?(conn.request_path, "/froth/voice"),
      do: "/froth/voice", else: "/api"
  end

  defp ep(conn), do: if(base_path(conn) == "/api", do: "/api/podcasts", else: "#{base_path(conn)}/episodes")

  # ── Root ──────────────────────────────────────────────

  def root(conn, _params) do
    bp = base_path(conn)
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Froth Voice", """
    <header>
      <h1>Froth Voice</h1>
      <p>Generated podcasts with cloned voices.<br>
      The wrapper is the problem. The payload was always fine.</p>
    </header>
    <nav>
      <a href="#{ep(conn)}">Episodes</a> ·
      <a href="#{bp}/voices">Voices</a> ·
      <a href="#{bp}/new">Create</a> ·
      <a href="#{bp}/archive">Archive</a> ·
      <a href="#{bp}/feed.xml">RSS</a>
    </nav>
    """))
  end

  # ── Voices ────────────────────────────────────────────

  def voices(conn, _params) do
    bp = base_path(conn)
    voices = Froth.VoiceClone.all()

    rows = Enum.map(voices, fn v ->
      """
      <tr vocab="https://schema.org/" typeof="Person">
        <td property="name">#{h(v.name)}</td>
        <td><code>#{h(v.voice_id)}</code></td>
        <td>#{h(v.character || "—")}</td>
        <td>#{h(v.language || "—")}</td>
      </tr>
      """
    end) |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Voices — #{length(voices)} clones", """
    #{nav(conn)}
    <h1>Voice Clones</h1>
    <p>#{length(voices)} voices. Use the <code>name</code> as the <code>speaker</code> field.</p>
    <table>
      <thead><tr><th>Name</th><th>Voice ID</th><th>Character</th><th>Language</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """))
  end

  # ── Episodes ──────────────────────────────────────────

  def index(conn, params) do
    limit = Map.get(params, "limit", "50") |> String.to_integer() |> min(100)
    offset = Map.get(params, "offset", "0") |> String.to_integer()

    scripts = Repo.all(
      from s in Froth.Podcast.Script,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset
    )

    total = Repo.aggregate(Froth.Podcast.Script, :count)

    cards = Enum.map(scripts, fn s ->
      speakers = (s.script || [])
      |> Enum.map(& &1["speaker"])
      |> Enum.uniq()
      |> Enum.join(", ")

      cover = if s.cover_url do
        """
        <img src="#{h(s.cover_url)}" alt="" class="ep-cover" loading="lazy">
        """
      else
        """
        <div class="ep-cover ep-cover-empty"></div>
        """
      end

      audio = if s.audio_url do
        """
        <audio controls preload="none" src="#{h(s.audio_url)}" class="ep-audio"></audio>
        """
      else
        ""
      end

      teaser = if s.teaser, do: "<p class=\"ep-teaser\">#{h(s.teaser)}</p>", else: ""

      """
      <article class="ep-card">
        #{cover}
        <div class="ep-body">
          <h3><a href="#{ep(conn)}/#{s.id}">#{h(s.label || "Episode ##{s.id}")}</a></h3>
          <p class="ep-meta">#{h(speakers)}</p>
          #{teaser}
          #{audio}
        </div>
      </article>
      """
    end) |> Enum.join("\n")

    pagination = []
    pagination = if offset > 0 do
      ["<a href=\"#{ep(conn)}?limit=#{limit}&offset=#{max(0, offset - limit)}\">← Newer</a>" | pagination]
    else
      pagination
    end
    pagination = if offset + limit < total do
      pagination ++ ["<a href=\"#{ep(conn)}?limit=#{limit}&offset=#{offset + limit}\">Older →</a>"]
    else
      pagination
    end

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Episodes — #{total}", """
    #{nav(conn)}
    <h1>Episodes</h1>
    <p>#{total} episodes. Showing #{offset + 1}–#{min(offset + limit, total)}.</p>
    <div class="ep-list">
      #{cards}
    </div>
    <p class="pagination">#{Enum.join(pagination, " · ")}</p>
    """))
  end

  # ── Show ──────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    case Repo.get(Froth.Podcast.Script, id) do
      nil ->
        conn
        |> put_resp_content_type("text/html")
        |> put_status(404)
        |> send_resp(404, page("Not Found", """
        #{nav(conn)}
        <h1>Episode ##{h(id)} not found.</h1>
        <p><a href="#{ep(conn)}">Browse all episodes</a>.</p>
        """))

      script ->
        cover = if script.cover_url do
          """
          <img src="#{h(script.cover_url)}" alt="" class="show-cover" loading="lazy">
          """
        else
          ""
        end

        audio = if script.audio_url do
          """
          <div class="show-audio">
            <audio controls preload="metadata" src="#{h(script.audio_url)}" style="width:100%;"></audio>
            <p><a href="#{h(script.audio_url)}" download>Download MP3</a></p>
          </div>
          """
        else
          case script.status do
            "queued" -> "<p><em>Generating...</em></p>"
            _ -> ""
          end
        end

        teaser = if script.teaser do
          "<p class=\"show-teaser\">#{h(script.teaser)}</p>"
        else
          ""
        end

        lines = (script.script || [])
        |> Enum.map(fn seg ->
          "<li><strong>#{h(seg["speaker"])}</strong>: #{h(seg["text"])}</li>"
        end)
        |> Enum.join("\n")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, page("#{h(script.label)}", """
        #{nav(conn)}
        <article class="show" vocab="https://schema.org/" typeof="PodcastEpisode">
          <div class="show-header">
            #{cover}
            <div>
              <h1 property="name">#{h(script.label || "Episode ##{script.id}")}</h1>
              #{teaser}
              #{audio}
            </div>
          </div>
          <dl class="show-meta">
            <dt>Status</dt><dd><code>#{h(script.status)}</code></dd>
            <dt>Batch</dt><dd><code>#{h(script.batch_id)}</code></dd>
            <dt>Created</dt><dd property="dateCreated">#{fmt(script.inserted_at)}</dd>
          </dl>
          <h2>Script</h2>
          <ol class="script">#{lines}</ol>
        </article>
        """))
    end
  end

  # ── New ───────────────────────────────────────────────

  def new(conn, _params) do
    bp = base_path(conn)
    voices = Froth.VoiceClone.all()
    opts = voices
    |> Enum.map(fn v -> "<option value=\"#{h(v.name)}\">#{h(v.name)}#{if v.character, do: " (#{h(v.character)})", else: ""}</option>" end)
    |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Create Episode", """
    #{nav(conn)}
    <h1>Create Episode</h1>
    <form method="POST" action="#{ep(conn)}">
      <fieldset>
        <legend>Script</legend>
        #{for _ <- 1..3 do "<div class=\"segment\"><label>Speaker: <select name=\"speaker[]\">#{opts}</select></label><label>Text: <textarea name=\"text[]\" rows=\"2\" cols=\"60\"></textarea></label></div>" end |> Enum.join("\n")}
      </fieldset>
      <fieldset>
        <legend>Options</legend>
        <label>Label: <input type="text" name="label" placeholder="Nikolai on the railgun" size="40" /></label><br>
        <label>Chat ID: <input type="number" name="chat_id" value="-1003690254489" /></label><br>
        <label>Pause (ms): <input type="number" name="pause_ms" value="400" min="0" max="3000" /></label><br>
        <label>Language: <input type="text" name="language" value="English" size="20" /></label><br>
        <label>Model: <input type="text" name="model" value="minimax/speech-2.8-hd" size="30" /></label>
      </fieldset>
      <button type="submit">Generate</button>
    </form>
    """))
  end

  # ── Create ────────────────────────────────────────────

  def create(conn, %{"speaker" => speakers, "text" => texts} = params) when is_list(speakers) do
    script = Enum.zip(speakers, texts)
    |> Enum.reject(fn {_, t} -> String.trim(t) == "" end)
    |> Enum.map(fn {s, t} -> {String.to_atom(s), t} end)
    do_create(conn, script, params)
  end

  def create(conn, %{"script" => data} = params) when is_list(data) do
    script = Enum.map(data, fn seg ->
      {String.to_atom(seg["speaker"] || seg["voice"]), seg["text"] || seg["line"]}
    end)
    do_create(conn, script, params)
  end

  def create(conn, _params) do
    conn |> put_resp_content_type("text/html") |> put_status(400)
    |> send_resp(400, page("Error", """
    #{nav(conn)}
    <h1>Missing script.</h1>
    <p><a href="#{base_path(conn)}/new">Use the form</a> or POST JSON.</p>
    """))
  end

  defp do_create(conn, script, params) when length(script) > 0 do
    chat_id = to_int(params["chat_id"], -1003690254489)
    label = params["label"]
    label = if is_binary(label) and String.trim(label) != "", do: label, else: "Episode"

    case Froth.Podcast.generate(script,
      chat_id: chat_id, label: label,
      pause_ms: to_int(params["pause_ms"], 400),
      language: params["language"] || "English",
      model: params["model"] || "minimax/speech-2.8-hd"
    ) do
      {:ok, batch_id} ->
        rec = Repo.one(from s in Froth.Podcast.Script, where: s.batch_id == ^batch_id, limit: 1)
        id = if rec, do: rec.id, else: batch_id
        conn
        |> put_resp_header("location", "#{ep(conn)}/#{id}")
        |> put_resp_content_type("text/html")
        |> put_status(303)
        |> send_resp(303, page("Created", "<p>Redirecting to <a href=\"#{ep(conn)}/#{id}\">episode</a>...</p>"))

      {:error, reason} ->
        conn |> put_resp_content_type("text/html") |> put_status(422)
        |> send_resp(422, page("Error", "<pre>#{h(inspect(reason))}</pre>"))
    end
  end

  defp do_create(conn, _, _) do
    conn |> put_resp_content_type("text/html") |> put_status(400)
    |> send_resp(400, page("Error", "<p>Empty script. <a href=\"#{base_path(conn)}/new\">Try again</a>.</p>"))
  end

  # ── RSS Feed ──────────────────────────────────────────

  def feed(conn, _params) do
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

      cover = if s.cover_url, do: "<itunes:image href=\"#{h(s.cover_url)}\" />", else: ""

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

  def archive(conn, _params) do
    audio_dir = Application.app_dir(:froth, "priv/static/audio")

    files = File.ls!(audio_dir)
    |> Enum.filter(&String.ends_with?(&1, ".mp3"))
    |> Enum.sort()
    |> Enum.map(fn filename ->
      %{size: size} = File.stat!(Path.join(audio_dir, filename))
      [_msg_id | rest] = String.split(filename, "-", parts: 2)
      caption = rest |> hd() |> String.replace("-", " ") |> String.replace(".mp3", "")
      %{filename: filename, caption: caption, size: size}
    end)

    total_size = files |> Enum.map(& &1.size) |> Enum.sum()

    rows = Enum.map(files, fn f ->
      """
      <tr>
        <td><audio controls preload="none" src="https://less.rest/audio/#{h(f.filename)}" class="archive-audio"></audio></td>
        <td>#{h(f.caption)}</td>
        <td style="text-align:right">#{div(f.size, 1024)}KB</td>
        <td><a href="https://less.rest/audio/#{h(f.filename)}" download>↓</a></td>
      </tr>
      """
    end) |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Archive — #{length(files)} files, #{div(total_size, 1024 * 1024)} MB", """
    #{nav(conn)}
    <h1>Audio Archive</h1>
    <p>#{length(files)} files. #{div(total_size, 1024 * 1024)} MB. Every audio message since February 12, 2026.</p>
    <table>
      <thead><tr><th></th><th>Caption</th><th style="text-align:right">Size</th><th></th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """))
  end

  # ── HTML ──────────────────────────────────────────────

  defp nav(conn) do
    bp = base_path(conn)
    """
    <nav>
      <a href="#{bp}">Voice</a> ·
      <a href="#{ep(conn)}">Episodes</a> ·
      <a href="#{bp}/voices">Voices</a> ·
      <a href="#{bp}/new">Create</a> ·
      <a href="#{bp}/archive">Archive</a> ·
      <a href="#{bp}/feed.xml">RSS</a>
    </nav>
    """
  end

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
          max-width: 64rem; margin: 0 auto; padding: 1rem;
          color: #111; background: #fff;
          line-height: 1.5;
        }
        h1 { font-size: 1.5rem; margin: 1rem 0 0.5rem; font-weight: 700; }
        h2 { font-size: 1.1rem; margin: 1.5rem 0 0.5rem; }
        h3 { font-size: 1rem; margin: 0 0 0.25rem; font-weight: 600; }
        h3 a { color: #111; text-decoration: none; }
        h3 a:hover { text-decoration: underline; }
        nav {
          font-size: 0.85rem; padding: 0.75rem 0;
          border-bottom: 1px solid #e5e5e5; margin-bottom: 1.5rem;
        }
        nav a { color: #555; text-decoration: none; }
        nav a:hover { color: #000; }
        table { width: 100%; border-collapse: collapse; font-size: 0.85rem; margin: 1rem 0; }
        th, td { text-align: left; padding: 0.4rem 0.5rem; border-bottom: 1px solid #f0f0f0; }
        th { font-weight: 600; border-bottom: 2px solid #ddd; }
        code { background: #f5f5f5; padding: 0.1rem 0.3rem; font-size: 0.85em; border-radius: 3px; }
        dl { margin: 1rem 0; }
        dt { font-weight: 600; margin-top: 0.5rem; font-size: 0.85rem; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
        dd { margin-left: 0; }
        fieldset { margin: 1rem 0; padding: 1rem; border: 1px solid #e5e5e5; border-radius: 4px; }
        legend { font-weight: 600; padding: 0 0.3rem; }
        label { display: block; margin: 0.5rem 0; font-size: 0.9rem; }
        textarea, input[type="text"], input[type="number"] {
          font-family: inherit; font-size: 0.9rem; padding: 0.4rem;
          border: 1px solid #ddd; border-radius: 3px; width: 100%; max-width: 40rem;
        }
        select { font-size: 0.9rem; padding: 0.3rem; border-radius: 3px; }
        button {
          margin: 1rem 0; padding: 0.6rem 2rem; font-size: 0.95rem;
          background: #111; color: #fff; border: none; border-radius: 4px; cursor: pointer;
        }
        button:hover { background: #333; }
        p { margin: 0.5rem 0; }

        /* Episode list */
        .ep-list { display: flex; flex-direction: column; gap: 1.25rem; margin: 1.5rem 0; }
        .ep-card {
          display: flex; gap: 1rem; padding: 1rem;
          background: #fafafa; border-radius: 6px;
          border: 1px solid #f0f0f0;
        }
        .ep-cover {
          width: 80px; height: 80px; object-fit: cover; border-radius: 4px;
          flex-shrink: 0;
        }
        .ep-cover-empty {
          background: #e5e5e5;
        }
        .ep-body { flex: 1; min-width: 0; }
        .ep-meta { font-size: 0.8rem; color: #888; margin: 0; }
        .ep-teaser { font-size: 0.85rem; color: #555; margin: 0.25rem 0; }
        .ep-audio { width: 100%; height: 32px; margin-top: 0.5rem; }

        /* Show page */
        .show-header { display: flex; gap: 1.5rem; margin-bottom: 1.5rem; }
        .show-cover { width: 160px; height: 160px; object-fit: cover; border-radius: 6px; flex-shrink: 0; }
        .show-teaser { font-size: 0.95rem; color: #555; font-style: italic; margin: 0.5rem 0; }
        .show-audio { margin: 1rem 0; }
        .show-meta { font-size: 0.85rem; }
        .script { margin: 1rem 0 1rem 1.5rem; font-size: 0.9rem; }
        .script li { margin: 0.4rem 0; }

        .archive-audio { height: 24px; width: 200px; }
        .segment { margin: 0.5rem 0; padding: 0.5rem; background: #f9f9f9; border-radius: 3px; }
        .pagination { margin: 1rem 0; font-size: 0.9rem; }
        footer {
          margin-top: 3rem; padding-top: 0.75rem; border-top: 1px solid #e5e5e5;
          font-size: 0.75rem; color: #999;
        }

        @media (max-width: 600px) {
          .ep-cover { width: 60px; height: 60px; }
          .show-header { flex-direction: column; }
          .show-cover { width: 120px; height: 120px; }
        }
      </style>
    </head>
    <body>
      #{body}
      <footer>
        <a href="/froth/voice">Froth Voice</a> ·
        <a href="/froth/voice/feed.xml">RSS</a> ·
        "The media type is text/html. It has been sufficient since 1993."
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

  defp fmt(nil), do: "—"
  defp fmt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_string(dt) |> String.slice(0..18)
  defp fmt(%DateTime{} = dt), do: DateTime.to_string(dt) |> String.slice(0..18)
  defp fmt(other), do: to_string(other)

  defp to_int(nil, d), do: d
  defp to_int(v, _) when is_integer(v), do: v
  defp to_int(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> d
    end
  end
  defp to_int(v, _) when is_float(v), do: round(v)
end
