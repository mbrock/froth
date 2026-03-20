defmodule FrothWeb.ReelController do
  use FrothWeb, :controller

  @doc """
  Serves a reel as a self-contained HTML page.
  The HTML includes the FrothVideo renderer, scenes, word timestamps,
  and audio. Opening it in a browser plays the reel in real time.
  """
  def show(conn, %{"id" => id}) do
    html_path = Path.join(reel_dir(), "#{id}.html")

    case File.read(html_path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Reel not found: #{id}")
    end
  end

  def index(conn, _params) do
    reels =
      case File.ls(reel_dir()) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".html"))
          |> Enum.map(&String.replace_suffix(&1, ".html", ""))
          |> Enum.sort()

        _ ->
          []
      end

    html = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Reels</title>
      <style>
        body { font-family: 'EB Garamond', Georgia, serif; background: #0a0a0a; color: #e0e0e0; padding: 2em; }
        a { color: #8ab4f8; text-decoration: none; }
        a:hover { text-decoration: underline; }
        h1 { font-size: 2em; font-weight: 400; letter-spacing: 0.05em; }
        ul { list-style: none; padding: 0; }
        li { margin: 0.5em 0; font-size: 1.2em; }
      </style>
    </head>
    <body>
      <h1>Reels</h1>
      <ul>
        #{Enum.map_join(reels, "\n", fn r -> "<li><a href=\"/reel/#{r}\">#{r}</a></li>" end)}
      </ul>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp reel_dir do
    Path.join(Application.app_dir(:froth, "priv"), "reels")
  end
end
