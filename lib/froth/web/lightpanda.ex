defmodule Froth.Web.Lightpanda do
  @moduledoc """
  Synchronous wrapper around the `lightpanda` CLI for one-shot web
  fetches.

  Lightpanda is a JS-enabled headless browser written in Zig (no
  Chrome, no rendering, no CSS) — perfect for "render this URL and
  give me the markdown back" without dragging in a real browser.

  For a fetch we just need stdout, no streaming, no interactivity, so
  this module uses plain `System.cmd/3` (matching how the codebase
  shells out to ffmpeg, yt-dlp, scp, etc.). `Port` is reserved for
  long-running, stateful tasks like `Froth.Tasks.Shell`.

  Wall-clock kill is handled by wrapping the invocation in
  `timeout(1)` from coreutils. On timeout the binary is sent SIGKILL,
  which `timeout` reports as exit status 137 — we surface that as
  `{:error, :timeout}`.

  ## Sandboxing

  We always pass `--block-private-networks` to keep server-side
  request forgery off the table: even if the model points us at a
  URL whose DNS resolves to RFC1918 space (or whose page tries to
  fetch private resources), the lightpanda HTTP client refuses.

  `--obey-robots` is on by default; this can be disabled per-call or
  globally via `Application.get_env(:froth, :lightpanda)`.

  ## Telemetry

      [:froth, :web, :lightpanda, :fetch, :start | :stop | :exception]

  Stop meta includes `exit_code`, `bytes`, and `outcome`
  (`:ok | :timeout | :error`).
  """

  alias Froth.Telemetry.Span

  @default_timeout_ms 30_000
  @default_wait_ms 5_000
  @default_http_timeout_ms 15_000

  @type fetch_opts :: [
          parent_id: String.t() | nil,
          format: :markdown | :html,
          timeout_ms: pos_integer(),
          wait_ms: pos_integer(),
          http_timeout_ms: pos_integer(),
          strip_mode: String.t() | nil,
          obey_robots: boolean(),
          extra_args: [String.t()]
        ]

  @doc """
  Fetch a URL through lightpanda and return the rendered output.

  Returns:

    * `{:ok, body}` — the dump (markdown or HTML).
    * `{:error, :timeout}` — wall-clock kill by `timeout(1)`.
    * `{:error, :missing_executable}` — `lightpanda` not on PATH.
    * `{:error, {:exit, code, stdout_tail}}` — non-zero exit.
  """
  @spec fetch(String.t(), fetch_opts()) ::
          {:ok, binary()}
          | {:error,
             :timeout
             | :missing_executable
             | {:exit, non_neg_integer(), binary()}}
  def fetch(url, opts \\ []) when is_binary(url) and is_list(opts) do
    config = configured_options(opts)
    parent_id = Keyword.get(opts, :parent_id)

    Span.span(
      [:froth, :web, :lightpanda, :fetch],
      parent_id,
      %{url: url, format: config.format, timeout_ms: config.timeout_ms},
      fn _span_id -> do_fetch(url, config) end
    )
  end

  defp do_fetch(url, config) do
    case System.find_executable("lightpanda") do
      nil ->
        {{:error, :missing_executable}, %{outcome: :missing_executable}}

      _ ->
        timeout_seconds = Integer.to_string(div(config.timeout_ms, 1000))

        args = [
          "--signal=KILL",
          timeout_seconds,
          "lightpanda" | lightpanda_args(url, config)
        ]

        case System.cmd("timeout", args, stderr_to_stdout: false) do
          {body, 0} ->
            {{:ok, body},
             %{outcome: :ok, exit_code: 0, bytes: byte_size(body)}}

          {_body, code} when code in [124, 137] ->
            {{:error, :timeout},
             %{outcome: :timeout, exit_code: code, bytes: 0}}

          {body, code} ->
            tail = body |> String.slice(-512..-1//1) |> to_string()

            {{:error, {:exit, code, tail}},
             %{outcome: :error, exit_code: code, bytes: byte_size(body)}}
        end
    end
  end

  defp lightpanda_args(url, config) do
    base = [
      "fetch",
      "--dump",
      Atom.to_string(config.format),
      "--block-private-networks",
      "--wait-until",
      "load",
      "--wait-ms",
      Integer.to_string(config.wait_ms),
      "--http-timeout",
      Integer.to_string(config.http_timeout_ms)
    ]

    base
    |> maybe_append("--strip-mode", config.strip_mode)
    |> maybe_append(
      "--obey-robots",
      if(config.obey_robots, do: "true", else: nil)
    )
    |> Kernel.++(config.extra_args)
    |> Kernel.++([url])
  end

  defp maybe_append(args, _flag, nil), do: args

  defp maybe_append(args, flag, "true") do
    args ++ [flag]
  end

  defp maybe_append(args, flag, value) when is_binary(value) do
    args ++ [flag, value]
  end

  defp configured_options(opts) do
    env = Application.get_env(:froth, __MODULE__, [])

    %{
      format:
        Keyword.get(opts, :format, Keyword.get(env, :format, :markdown)),
      timeout_ms:
        Keyword.get(
          opts,
          :timeout_ms,
          Keyword.get(env, :timeout_ms, @default_timeout_ms)
        ),
      wait_ms:
        Keyword.get(
          opts,
          :wait_ms,
          Keyword.get(env, :wait_ms, @default_wait_ms)
        ),
      http_timeout_ms:
        Keyword.get(
          opts,
          :http_timeout_ms,
          Keyword.get(env, :http_timeout_ms, @default_http_timeout_ms)
        ),
      strip_mode:
        Keyword.get(opts, :strip_mode, Keyword.get(env, :strip_mode, "full")),
      obey_robots:
        Keyword.get(opts, :obey_robots, Keyword.get(env, :obey_robots, true)),
      extra_args:
        Keyword.get(opts, :extra_args, Keyword.get(env, :extra_args, []))
    }
  end
end
