defmodule FrothWeb.EmbedController do
  @moduledoc """
  Embeddable podcast player and audio endpoint.

  Endpoints:
    GET /embed/:batch_id        — embeddable HTML player (audio + transcript)
    GET /embed/:batch_id/audio  — raw MP3 audio file
    GET /embed/:batch_id/reel   — redirect to reel if available
  """
  use FrothWeb, :controller

  def show(conn, %{"batch_id" => batch_id}) do
    batch_id = sanitize(batch_id)
    audio_url = "/embed/#{batch_id}/audio"
    reel_url = "/reel/#{batch_id}"

    # Check if reel exists
    reel_dir = Path.join(Application.app_dir(:froth, "priv"), "reels")
    has_reel = File.exists?(Path.join(reel_dir, "#{batch_id}.html"))

    html = embed_html(batch_id, audio_url, reel_url, has_reel)

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("x-frame-options", "ALLOWALL")
    |> delete_resp_header("x-frame-options")
    |> send_resp(200, html)
  end

  def audio(conn, %{"batch_id" => batch_id}) do
    batch_id = sanitize(batch_id)

    # Try persistent location first, then /tmp
    path = find_audio(batch_id)

    case path do
      nil ->
        conn |> send_resp(404, "Audio not found for #{batch_id}")

      path ->
        conn
        |> put_resp_content_type("audio/mpeg")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> put_resp_header("accept-ranges", "bytes")
        |> send_file(200, path)
    end
  end

  defp find_audio(batch_id) do
    persistent = Path.join(audio_dir(), "#{batch_id}.mp3")
    tmp = "/tmp/podcast_#{batch_id}_final.mp3"

    cond do
      File.exists?(persistent) ->
        persistent

      File.exists?(tmp) ->
        # Persist it for future use
        File.mkdir_p!(audio_dir())
        File.cp!(tmp, persistent)
        persistent

      true ->
        nil
    end
  end

  defp audio_dir do
    Path.join(Application.app_dir(:froth, "priv"), "static/audio/hourly")
  end

  defp sanitize(id) do
    id |> String.replace(~r/[^a-zA-Z0-9_-]/, "") |> String.slice(0, 32)
  end

  defp embed_html(batch_id, audio_url, reel_url, has_reel) do
    reel_link =
      if has_reel do
        ~s(<a href="#{reel_url}" target="_blank" class="reel-link">Watch Reel</a>)
      else
        ""
      end

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{batch_id}</title>
      <style>
        @import url('https://fonts.googleapis.com/css2?family=EB+Garamond:wght@400;500;600&display=swap');

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: 'EB Garamond', Georgia, serif;
          background: #0a0a0a;
          color: #d4d4d4;
          padding: 1.2em;
        }
        .player {
          max-width: 480px;
          margin: 0 auto;
        }
        .title {
          font-size: 1.1em;
          font-weight: 500;
          font-variant: small-caps;
          letter-spacing: 0.1em;
          color: #888;
          margin-bottom: 0.8em;
        }
        audio {
          width: 100%;
          height: 40px;
          filter: invert(1) hue-rotate(180deg);
          opacity: 0.8;
        }
        audio::-webkit-media-controls-panel {
          background: #1a1a1a;
        }
        .links {
          margin-top: 0.8em;
          display: flex;
          gap: 1em;
          font-size: 0.85em;
        }
        .links a {
          color: #64d2ff;
          text-decoration: none;
          font-variant: small-caps;
          letter-spacing: 0.05em;
        }
        .links a:hover { text-decoration: underline; }
      </style>
    </head>
    <body>
      <div class="player">
        <div class="title">#{batch_id}</div>
        <audio controls preload="metadata" src="#{audio_url}"></audio>
        <div class="links">
          <a href="#{audio_url}" download>Download MP3</a>
          #{reel_link}
        </div>
      </div>
    </body>
    </html>
    """
  end
end
