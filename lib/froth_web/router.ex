defmodule FrothWeb.Router do
  use FrothWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FrothWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :mini do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {FrothWeb.Layouts, :mini_root}
  end

  scope "/froth", FrothWeb do
    pipe_through :browser

    get "/summaries", SummariesController, :index
    live "/", AnalysesLive, :index
    live "/analyses", AnalysesLive, :index
    live "/analyses/:day", AnalysesLive, :index
    live "/inference", InferenceSessionsLive, :index
    live "/inference/:id", InferenceSessionsLive, :show
    live "/dataset", DatasetLive, :index
    live "/rdf", RdfLive, :index
    live "/wiki", WikiLive, :index
    live "/wiki/:slug", WikiLive, :show
    get "/media/:chat_id/:message_id", MediaController, :show
    live "/voice", VoiceLive, :index
  end

  scope "/froth/mini", FrothWeb do
    pipe_through :mini

    live "/app", ToolLive, :landing
    live "/tool", ToolLive, :landing
    live "/tool/:ref", ToolLive, :show
    live "/codex", CodexLive, :index
    live "/codex/thread/:thread_id", CodexLive, :index
    live "/codex/:session_id", CodexLive, :index
  end

  scope "/froth/mini", FrothWeb do
    pipe_through :api

    post "/debug", MiniDebugController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", FrothWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:froth, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FrothWeb.Telemetry
    end
  end
end
