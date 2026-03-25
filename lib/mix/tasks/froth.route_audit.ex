defmodule Mix.Tasks.Froth.RouteAudit do
  @moduledoc """
  Capture screenshots and summaries for Froth GET routes.

      mix froth.route_audit
      mix froth.route_audit --base-url https://less.rest --full-page
  """
  @shortdoc "Audit routes with screenshots"

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          base_url: :string,
          output_dir: :string,
          full_page: :boolean,
          navigation_timeout_ms: :integer,
          settle_ms: :integer,
          wait_timeout_ms: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    end

    Mix.Task.run("app.start")

    case Froth.RouteAudit.run(opts) do
      {:ok, summary} ->
        Mix.shell().info("Route audit complete.")
        Mix.shell().info("Summary: #{summary.summary_path}")
        Mix.shell().info("Markdown: #{summary.markdown_path}")

      {:error, reason} ->
        Mix.raise("Route audit failed: #{inspect(reason)}")
    end
  end
end
