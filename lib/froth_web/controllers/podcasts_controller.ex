defmodule FrothWeb.PodcastsController do
  use FrothWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    scripts =
      Froth.Repo.all(
        from(s in Froth.Podcast.Script,
          order_by: [desc: s.inserted_at]
        )
      )

    total_duration =
      scripts
      |> Enum.map(fn s -> length(s.script || []) end)
      |> Enum.sum()

    conn
    |> assign(:page_title, "Podcasts")
    |> assign(:scripts, scripts)
    |> assign(:total, length(scripts))
    |> assign(:total_segments, total_duration)
    |> render(:index)
  end
end
