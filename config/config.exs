# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :froth,
  ecto_repos: [Froth.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :froth, FrothWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FrothWeb.ErrorHTML, json: FrothWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Froth.PubSub,
  live_view: [signing_salt: "nDsQEiH7"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  froth: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  froth: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger,
  level: :debug,
  handle_sasl_reports: false,
  translators: [{Froth.LogTranslator, :translate}]

# Default handler: compact text to stderr (for journal/terminal)
config :logger, :default_handler, formatter: {Froth.LogFormatter, %{}}

# JSON file handler: daily logs with rotation
config :froth, :logger, [
  {:handler, :json_file, :logger_std_h,
   %{
     config: %{
       file: ~c"log/froth.log",
       max_no_bytes: 10_000_000,
       max_no_files: 10,
       compress_on_rotate: true
     },
     formatter: {LoggerJSON.Formatters.Basic, metadata: :all}
   }}
]

config :logger_json, encoder: JSON

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason
config :floki, :html_parser, Floki.HTMLParser.FastHtml

config :froth, Oban,
  engine: Oban.Engines.Basic,
  repo: Froth.Repo,
  queues: [
    youtube: 4,
    xpost: 4,
    image: 4,
    voice: 2,
    video: 2,
    pdf: 8,
    replicate: 4,
    github: 10,
    podcast: 6
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 3600 * 24, limit: 5000},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

config :froth, Froth.Telegram.Bot, [
  [
    id: "barble",
    session_id: "agentbot",
    bot_username: "barblebot",
    system_prompt:
      "You are Barble, a helpful and concise assistant on Telegram. Keep responses short and direct."
  ]
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
