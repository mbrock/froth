defmodule FrothWeb.HeadlinesController do
  use FrothWeb, :controller

  alias Froth.HeadlinesLedger

  def index(conn, params) do
    conn
    |> assign(:page_title, "Headlines")
    |> render(:index, HeadlinesLedger.build(params))
  end
end
