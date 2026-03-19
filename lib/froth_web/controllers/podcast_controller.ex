defmodule FrothWeb.PodcastController do
  @moduledoc """
  Podcast API as HTML hypermedia.

  Not JSON with _links pretending to be REST.
  Actual HTML. Forms are the affordances. Links are the state transitions.
  The browser is the universal client. curl sees the same thing.

  "A REST API should spend almost all of its descriptive effort in defining
  the media type(s) used for representing resources and driving application
  state." — Roy Fielding, 2008

  The media type is text/html. It has been sufficient since 1993.
  """
  use FrothWeb, :controller
  alias Froth.Repo
  import Ecto.Query

  # We bypass the root layout and render our own minimal HTML.
  # No Phoenix JS, no LiveView, no app.css. Just HTML.

  plug :put_layout, false

  # ── Root ──────────────────────────────────────────────

  def root(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Froth Podcast API", """
    <header>
      <h1>Froth Podcast API</h1>
      <p>Generate podcasts with cloned voices.<br>
      The wrapper is the problem. The payload was always fine.</p>
    </header>
    <nav>
      <a href="/api/podcasts">Podcasts</a> ·
      <a href="/api/voices">Voices</a> ·
      <a href="/api/podcasts/new">Create</a>
    </nav>
    """))
  end

  # ── Voices ────────────────────────────────────────────

  def voices(conn, _params) do
    voices = Froth.VoiceClone.all()

    rows = Enum.map(voices, fn v ->
      """
      <tr vocab="https://schema.org/" typeof="Person">
        <td property="name">#{h(v.name)}</td>
        <td>#{h(v.voice_id)}</td>
        <td>#{h(v.character || "—")}</td>
        <td>#{h(v.language || "—")}</td>
        <td><code>#{h(v.tts_model || "—")}</code></td>
      </tr>
      """
    end) |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Voices — #{length(voices)} clones", """
    <nav><a href="/api">← API root</a> · <a href="/api/podcasts">Podcasts</a> · <a href="/api/podcasts/new">Create</a></nav>
    <h1>Voice Clones</h1>
    <p>#{length(voices)} voices available. Use the <code>name</code> as the <code>speaker</code> field when creating podcasts.</p>
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

  # ── List Podcasts ─────────────────────────────────────

  def index(conn, params) do
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

      """
      <tr>
        <td><a href="/api/podcasts/#{s.id}">#{s.id}</a></td>
        <td>#{h(s.label || "—")}</td>
        <td><code>#{h(s.status)}</code></td>
        <td>#{h(speakers)}</td>
        <td>#{format_time(s.inserted_at)}</td>
      </tr>
      """
    end) |> Enum.join("\n")

    nav_links = []
    nav_links = if offset > 0 do
      ["<a href=\"/api/podcasts?limit=#{limit}&offset=#{max(0, offset - limit)}\">← Previous</a>" | nav_links]
    else
      nav_links
    end
    nav_links = if offset + limit < total do
      nav_links ++ ["<a href=\"/api/podcasts?limit=#{limit}&offset=#{offset + limit}\">Next →</a>"]
    else
      nav_links
    end
    pagination = Enum.join(nav_links, " · ")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Podcasts — #{total} total", """
    <nav><a href="/api">← API root</a> · <a href="/api/voices">Voices</a> · <a href="/api/podcasts/new">Create</a></nav>
    <h1>Podcasts</h1>
    <p>#{total} podcasts. Showing #{offset + 1}–#{min(offset + limit, total)}.</p>
    <table>
      <thead>
        <tr><th>ID</th><th>Label</th><th>Status</th><th>Speakers</th><th>Created</th></tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    <p>#{pagination}</p>
    """))
  end

  # ── Show Podcast ──────────────────────────────────────

  def show(conn, %{"id" => id}) do
    case Repo.get(Froth.Podcast.Script, id) do
      nil ->
        conn
        |> put_resp_content_type("text/html")
        |> put_status(404)
        |> send_resp(404, page("Not Found", """
        <nav><a href="/api/podcasts">← All podcasts</a></nav>
        <h1>Podcast ##{h(id)} not found.</h1>
        <p>Try <a href="/api/podcasts">browsing all podcasts</a>
        or <a href="/api/podcasts/new">creating a new one</a>.</p>
        """))

      script ->
        lines = (script.script || [])
        |> Enum.map(fn seg ->
          "<li><strong>#{h(seg["speaker"])}</strong>: #{h(seg["text"])}</li>"
        end)
        |> Enum.join("\n")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, page("Podcast ##{script.id} — #{h(script.label)}", """
        <nav><a href="/api/podcasts">← All podcasts</a> · <a href="/api/voices">Voices</a></nav>
        <h1 property="name">#{h(script.label || "Podcast ##{script.id}")}</h1>
        <dl>
          <dt>Status</dt><dd><code>#{h(script.status)}</code></dd>
          <dt>Batch</dt><dd><code>#{h(script.batch_id)}</code></dd>
          <dt>Chat ID</dt><dd>#{script.chat_id}</dd>
          <dt>Created</dt><dd>#{format_time(script.inserted_at)}</dd>
        </dl>
        <h2>Script</h2>
        <ol>#{lines}</ol>
        """))
    end
  end

  # ── New (the form) ────────────────────────────────────
  # The form IS the API documentation.
  # The form IS the client library.
  # The form IS the affordance.

  def new(conn, _params) do
    voices = Froth.VoiceClone.all()
    voice_options = voices
    |> Enum.map(fn v -> "<option value=\"#{h(v.name)}\">#{h(v.name)}#{if v.character, do: " (#{h(v.character)})", else: ""}</option>" end)
    |> Enum.join("\n")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page("Create Podcast", """
    <nav><a href="/api">← API root</a> · <a href="/api/podcasts">Podcasts</a> · <a href="/api/voices">Voices</a></nav>
    <h1>Create Podcast</h1>
    <form method="POST" action="/api/podcasts">
      <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />

      <fieldset>
        <legend>Script</legend>
        <p>One segment per row. Add more by submitting and editing.</p>
        <div id="segments">
          <div class="segment">
            <label>Speaker:
              <select name="speaker[]">
                #{voice_options}
              </select>
            </label>
            <label>Text:
              <textarea name="text[]" rows="2" cols="60" placeholder="That's the whole thing."></textarea>
            </label>
          </div>
          <div class="segment">
            <label>Speaker:
              <select name="speaker[]">
                #{voice_options}
              </select>
            </label>
            <label>Text:
              <textarea name="text[]" rows="2" cols="60" placeholder=""></textarea>
            </label>
          </div>
          <div class="segment">
            <label>Speaker:
              <select name="speaker[]">
                #{voice_options}
              </select>
            </label>
            <label>Text:
              <textarea name="text[]" rows="2" cols="60" placeholder=""></textarea>
            </label>
          </div>
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

      <button type="submit">Generate Podcast</button>
    </form>
    """))
  end

  # ── Create (POST) ─────────────────────────────────────
  # Accepts both form-encoded (from the HTML form) and JSON.

  def create(conn, %{"speaker" => speakers, "text" => texts} = params) when is_list(speakers) do
    # Form submission — parallel arrays
    script = Enum.zip(speakers, texts)
    |> Enum.reject(fn {_, text} -> String.trim(text) == "" end)
    |> Enum.map(fn {speaker, text} -> {String.to_atom(speaker), text} end)

    do_create(conn, script, params)
  end

  def create(conn, %{"script" => script_data} = params) when is_list(script_data) do
    # JSON submission
    script = Enum.map(script_data, fn seg ->
      {String.to_atom(seg["speaker"] || seg["voice"]), seg["text"] || seg["line"]}
    end)
    do_create(conn, script, params)
  end

  def create(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> put_status(400)
    |> send_resp(400, page("Error", """
    <nav><a href="/api/podcasts/new">← Try again</a></nav>
    <h1>Missing script.</h1>
    <p>Submit a script with speaker/text pairs.
    <a href="/api/podcasts/new">Use the form</a> or POST JSON.</p>
    """))
  end

  defp do_create(conn, script, params) when length(script) > 0 do
    chat_id = to_int(params["chat_id"], -1003690254489)
    label = params["label"]
    label = if is_binary(label) and String.trim(label) != "", do: label, else: "Podcast"

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
        |> put_resp_header("location", "/api/podcasts/#{id}")
        |> put_resp_content_type("text/html")
        |> put_status(303)
        |> send_resp(303, page("Created", """
        <nav><a href="/api/podcasts/#{id}">→ View podcast ##{id}</a></nav>
        <h1>Podcast queued.</h1>
        <p>Redirecting to <a href="/api/podcasts/#{id}">/api/podcasts/#{id}</a>...</p>
        """))

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_status(422)
        |> send_resp(422, page("Error", """
        <nav><a href="/api/podcasts/new">← Try again</a></nav>
        <h1>Generation failed.</h1>
        <pre>#{h(inspect(reason))}</pre>
        """))
    end
  end

  defp do_create(conn, _script, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> put_status(400)
    |> send_resp(400, page("Error", """
    <nav><a href="/api/podcasts/new">← Try again</a></nav>
    <h1>Empty script.</h1>
    <p>Add at least one segment with text. <a href="/api/podcasts/new">Use the form</a>.</p>
    """))
  end

  # ── HTML scaffold ─────────────────────────────────────
  # No framework. No build step. No CDN. The style is inline
  # because the document should be self-contained.

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
        footer { margin-top: 2rem; padding-top: 0.5rem; border-top: 1px solid #ddd;
          font-size: 0.75rem; color: #999; }
      </style>
    </head>
    <body>
      #{body}
      <footer>
        <a href="/api">API root</a> · Froth Podcast Engine ·
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
