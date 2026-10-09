defmodule Mix.Tasks.Froth.Telegram.VaultBackfill do
  @moduledoc """
  Backfill a Telegram session from Telethon JSON dumps on vault.

  The command is a dry run unless `--insert` is explicitly supplied:

      mix froth.telegram.vault_backfill --session charlie --chat-id -1003690254489 \
        --from 2026-08-25 --to 2026-10-09

  Use `--staging-dir PATH --no-pull` to reuse previously downloaded files.
  """
  @shortdoc "Backfill TDLib-shaped Telegram rows from vault"

  use Mix.Task

  alias Froth.Telegram.Backfill

  @switches [
    session: :string,
    chat_id: :integer,
    from: :string,
    to: :string,
    staging_dir: :string,
    host: :string,
    remote_dir: :string,
    pull: :boolean,
    insert: :boolean,
    samples: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [],
      do: abort("Invalid arguments: #{inspect(positional ++ invalid)}")

    session = required!(opts, :session)
    chat_id = required!(opts, :chat_id)
    from = parse_date!(required!(opts, :from), "--from")
    to = parse_date!(required!(opts, :to), "--to")
    if Date.after?(from, to), do: abort("--from must not be after --to")

    staging_dir =
      Keyword.get_lazy(opts, :staging_dir, fn ->
        Path.join(
          System.tmp_dir!(),
          "froth-telegram-vault-#{session}-#{from}-#{to}"
        )
      end)

    pull_opts =
      [from: from, to: to, chat_id: chat_id, staging_dir: staging_dir]
      |> maybe_put(:host, opts[:host])
      |> maybe_put(:remote_dir, opts[:remote_dir])

    if Keyword.get(opts, :pull, true) do
      Mix.shell().info("Pulling relay JSON into #{staging_dir}...")
      Backfill.pull!(pull_opts)
    end

    translations = Backfill.load(staging_dir, chat_id)
    report = Backfill.dry_run(translations, Keyword.get(opts, :samples, 3))
    print_report(report)

    if Keyword.get(opts, :insert, false) do
      Mix.Task.run("app.start")
      inserted = Backfill.insert(session, translations)

      Mix.shell().info(
        "Inserted #{inserted} new rows for session #{session}."
      )
    else
      Mix.shell().info("Dry run only; pass --insert to write rows.")
    end
  end

  defp print_report(report) do
    Mix.shell().info(
      "Translated #{report.total} messages; #{length(report.errors)} errors."
    )

    Enum.each(report.per_day, fn {date, count} ->
      Mix.shell().info("#{date}  #{count}")
    end)

    if report.errors != [] do
      Enum.each(Enum.take(report.errors, 10), fn {path, reason} ->
        Mix.shell().error("#{Path.basename(path)}: #{inspect(reason)}")
      end)
    end

    Enum.each(report.samples, fn sample ->
      Mix.shell().info("\n" <> Jason.encode!(sample, pretty: true))
    end)
  end

  defp required!(opts, key),
    do:
      Keyword.get(opts, key) ||
        abort("Missing --#{String.replace(to_string(key), "_", "-")}")

  defp parse_date!(value, flag) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> abort("#{flag} must be YYYY-MM-DD")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp abort(message), do: Mix.raise(message)
end
