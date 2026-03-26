import Config

if config_env() in [:dev, :test] do
  Dotenvy.source!([".env", System.get_env()],
    side_effect: fn vars ->
      for {k, v} <- vars, do: System.put_env(k, v)
    end
  )
end

node_role =
  case System.get_env("FROTH_NODE_ROLE", "full") |> String.trim() |> String.downcase() do
    "worker" -> :worker
    _ -> :full
  end

endpoint_http =
  [port: String.to_integer(System.get_env("PORT", "4000"))]
  |> then(fn http ->
    case System.get_env("FROTH_HTTP_IP") do
      nil ->
        http

      value ->
        case value
             |> String.trim()
             |> String.split(".", trim: true)
             |> Enum.map(&Integer.parse/1) do
          [{a, ""}, {b, ""}, {c, ""}, {d, ""}] ->
            Keyword.put(http, :ip, {a, b, c, d})

          _ ->
            http
        end
    end
  end)

config :froth, :node_role, node_role

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/froth start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :froth, FrothWeb.Endpoint, server: true
end

config :froth, FrothWeb.Endpoint, http: endpoint_http
config :froth, Froth.Telemetry.Store, enabled: config_env() != :test and node_role != :worker

# The app usually runs on the host while Fuseki runs in Docker, so localhost is
# the right default here. Override this when Froth itself runs in Docker or the
# SPARQL service is reachable on a different network path.
config :froth, Froth.Dataset,
  endpoint: System.get_env("FROTH_SPARQL_ENDPOINT", "http://localhost:3030/kg/sparql"),
  query_opts: [request_method: :post, protocol_version: "1.1"]

config :froth, Froth.Browser,
  executable: System.get_env("FROTH_BROWSER_EXECUTABLE"),
  profile:
    (case System.get_env("FROTH_BROWSER_PROFILE") do
       nil -> :headless_bulk
       value -> value
     end),
  tmp_dir: System.get_env("FROTH_BROWSER_TMP_DIR", Path.expand("tmp/browser")),
  artifact_dir:
    System.get_env("FROTH_BROWSER_ARTIFACT_DIR", Path.expand("tmp/browser-artifacts")),
  launch_timeout_ms:
    (case System.get_env("FROTH_BROWSER_LAUNCH_TIMEOUT_MS") do
       nil -> 15_000
       value -> String.to_integer(value)
     end),
  command_timeout_ms:
    (case System.get_env("FROTH_BROWSER_COMMAND_TIMEOUT_MS") do
       nil -> 10_000
       value -> String.to_integer(value)
     end),
  navigation_timeout_ms:
    (case System.get_env("FROTH_BROWSER_NAVIGATION_TIMEOUT_MS") do
       nil -> 15_000
       value -> String.to_integer(value)
     end)

config :froth, Froth.Video,
  render_dir: System.get_env("FROTH_VIDEO_RENDER_DIR", Path.expand("tmp/video-renders")),
  compute_worker_count:
    (case System.get_env("FROTH_VIDEO_COMPUTE_WORKER_COUNT") do
       nil -> 2
       value -> String.to_integer(value)
     end)

config :froth, Froth.ObjectStore,
  mode:
    (case System.get_env("FROTH_OBJECT_STORE_MODE", "local") do
       "proxy" -> :proxy
       _ -> :local
     end),
  root_dir: System.get_env("FROTH_OBJECT_STORE_ROOT_DIR", Path.expand("tmp/object-store")),
  public_base: System.get_env("FROTH_OBJECT_STORE_PUBLIC_BASE"),
  internal_base: System.get_env("FROTH_OBJECT_STORE_INTERNAL_BASE"),
  write_token: System.get_env("FROTH_OBJECT_STORE_TOKEN")

config :froth, Froth.Summarizer,
  recent_context_chunk_size:
    (case System.get_env("SUMMARIZER_RECENT_CONTEXT_CHUNK_SIZE") do
       nil ->
         50

       value ->
         case Integer.parse(value) do
           {n, ""} when n > 0 -> n
           _ -> 50
         end
     end)

config :froth, Froth.Anthropic,
  model: System.get_env("ANTHROPIC_MODEL", "claude-opus-4-6"),
  system: System.get_env("ANTHROPIC_SYSTEM", ""),
  max_tokens:
    (case System.get_env("ANTHROPIC_MAX_TOKENS", "16384") do
       value ->
         case Integer.parse(value) do
           {n, ""} when n > 0 -> n
           _ -> 16_384
         end
     end),
  output_config:
    (case System.get_env("ANTHROPIC_EFFORT", "") |> String.downcase() |> String.trim() do
       "" ->
         nil

       effort when effort in ["low", "medium", "high", "max"] ->
         %{"effort" => effort}

       _ ->
         nil
     end),
  thinking:
    (case System.get_env("ANTHROPIC_THINKING", "adaptive") do
       "0" ->
         nil

       "false" ->
         nil

       "disabled" ->
         nil

       "adaptive" ->
         %{"type" => "adaptive"}

       _ ->
         budget =
           System.get_env("ANTHROPIC_THINKING_BUDGET_TOKENS", "1024")
           |> String.to_integer()

         %{"type" => "enabled", "budget_tokens" => budget}
     end)

config :froth, Froth.OpenAI,
  model: System.get_env("OPENAI_MODEL", "gpt-5-mini"),
  system: System.get_env("OPENAI_SYSTEM", ""),
  max_tokens:
    (case System.get_env("OPENAI_MAX_TOKENS", "16384") do
       value ->
         case Integer.parse(value) do
           {n, ""} when n > 0 -> n
           _ -> 16_384
         end
     end),
  effort:
    (case System.get_env("OPENAI_EFFORT", "") |> String.downcase() |> String.trim() do
       "" -> nil
       effort -> effort
     end)

config :froth, Froth.Grok,
  model: System.get_env("GROK_MODEL", "grok-4-1-fast-non-reasoning"),
  system: System.get_env("GROK_SYSTEM", ""),
  max_tokens:
    (case System.get_env("GROK_MAX_TOKENS", "16384") do
       value ->
         case Integer.parse(value) do
           {n, ""} when n > 0 -> n
           _ -> 16_384
         end
     end),
  effort:
    (case System.get_env("GROK_EFFORT", "") |> String.downcase() |> String.trim() do
       "" -> nil
       effort -> effort
     end)

config :froth, Froth.Gemini,
  model: System.get_env("GEMINI_MODEL", "gemini-3-flash-preview"),
  system: System.get_env("GEMINI_SYSTEM", ""),
  max_tokens:
    (case System.get_env("GEMINI_MAX_TOKENS", "16384") do
       value ->
         case Integer.parse(value) do
           {n, ""} when n > 0 -> n
           _ -> 16_384
         end
     end),
  effort:
    (case System.get_env("GEMINI_EFFORT", "") |> String.downcase() |> String.trim() do
       "" -> nil
       effort -> effort
     end)

config :froth, Froth.Analyzer, tdlib_session: System.get_env("ANALYZER_TDLIB_SESSION")

config :froth, Froth.Podcast,
  docroot: System.get_env("PODCAST_DOCROOT"),
  public_base: System.get_env("PODCAST_PUBLIC_BASE")

config :froth, Froth.Telegram.Charlie,
  bot_user_id: String.to_integer(System.get_env("CHARLIE_BOT_USER_ID", "0")),
  owner_user_id: String.to_integer(System.get_env("CHARLIE_OWNER_USER_ID", "0"))

lennart_bot_user_id =
  String.to_integer(
    System.get_env("LENNART_BOT_USER_ID") || System.get_env("BERTIL_BOT_USER_ID") || "0"
  )

lennart_owner_user_id =
  String.to_integer(
    System.get_env("LENNART_OWNER_USER_ID") || System.get_env("BERTIL_OWNER_USER_ID") || "0"
  )

config :froth, Froth.Telegram.Lennart,
  bot_user_id: lennart_bot_user_id,
  owner_user_id: lennart_owner_user_id

config :froth, Froth.Telegram,
  # optional override for where the built executable lives
  cnode_executable: System.get_env("TELEGRAM_TDLIB_CNODE_EXECUTABLE"),
  # optional overrides for distributed Erlang identity used by the shared cnode
  cnode_node: System.get_env("TELEGRAM_TDLIB_CNODE_NODE"),
  server_name: System.get_env("TELEGRAM_TDLIB_CNODE_SERVER"),
  # optional override for explicit TgCalls registration plugin path
  tgcalls_plugin:
    System.get_env("TELEGRAM_TGCALLS_PLUGIN") || System.get_env("FROTH_TGCALLS_PLUGIN")

config :libcluster, topologies: Froth.Cluster.topologies()

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :froth, Froth.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :froth, FrothWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :froth, FrothWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :froth, FrothWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
