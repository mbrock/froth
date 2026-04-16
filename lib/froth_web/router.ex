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
    pipe_through :api

    get "/analyses", AnalysesApiController, :index
    get "/analyses/:chat_id", AnalysesApiController, :show
  end

  scope "/froth", FrothWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/objects/*key", ObjectStoreController, :show
    get "/summaries", SummariesController, :index
    get "/headlines", HeadlinesController, :index
    get "/podcasts", PodcastsController, :index
    live "/analyses/day", AnalysesLive, :index
    live "/analyses/day/:day", AnalysesLive, :index
    live "/inference", InferenceSessionsLive, :index
    live "/inference/:id", InferenceSessionsLive, :show
    live "/dataset", DatasetLive, :index
    live "/rdf", RdfLive, :index
    live "/wiki", WikiLive, :index
    live "/wiki/:slug", WikiLive, :show
    get "/media/:chat_id/:message_id", MediaController, :show
    live "/bot-context", BotContextLive, :index
    live "/follow", FollowLive, :index
    live "/telemetry", TelemetryLive, :index
    live "/chat-stats", ChatStatsLive, :index
    live "/chat-stats/:day", ChatStatsLive, :index
    live "/jobs", JobsLive, :index
    live "/scene", SceneLive, :index
    live "/scene/:id", SceneLive, :index
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

  scope "/froth", FrothWeb do
    post "/objects", ObjectStoreController, :create
    put "/objects/*key", ObjectStoreController, :put
  end

  scope "/", FrothWeb do
    pipe_through :browser

    live "/jbo", JboLive, :index
  end

  # Embed player
  # RFC viewer
  scope "/rfc", FrothWeb do
    pipe_through :browser
    get "/", RfcController, :index
    get "/:slug", RfcController, :show
  end

  scope "/embed", FrothWeb do
    get "/:batch_id", EmbedController, :show
    get "/:batch_id/audio", EmbedController, :audio
  end

  # Reel preview
  scope "/reel", FrothWeb do
    get "/", ReelController, :index
    get "/:id", ReelController, :show
  end

  # Voice — HTML hypermedia for podcast generation
  scope "/froth/voice", FrothWeb do
    pipe_through :api

    get "/", PodcastController, :root
    get "/voices", PodcastController, :voices
    get "/new", PodcastController, :new
    get "/episodes", PodcastController, :index
    get "/episodes/:id", PodcastController, :show
    post "/episodes", PodcastController, :create
    get "/archive", PodcastController, :archive
    get "/feed.xml", PodcastController, :feed
  end

  # Legacy /api redirect
  scope "/api", FrothWeb do
    pipe_through :api

    get "/", PodcastController, :root
    get "/voices", PodcastController, :voices
    get "/podcasts/new", PodcastController, :new
    get "/podcasts", PodcastController, :index
    get "/podcasts/:id", PodcastController, :show
    post "/podcasts", PodcastController, :create
    get "/archive", PodcastController, :archive
  end

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
