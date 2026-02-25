defmodule FrothWeb.PageController do
  use FrothWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
