defmodule Mix.Tasks.Froth.Summarize.Weekly do
  @moduledoc """
  Backfill missing weekly chronicle chapters on the running Froth node.

      mix froth.summarize.weekly

  Opus thinking and chapter text are streamed to this terminal while each
  completed UTC range is generated and saved.
  """

  @shortdoc "Backfill weekly chronicle chapters via RPC"

  use Mix.Task

  alias Froth.Mix.LiveNode

  @chat_id -1_003_690_254_489

  @impl Mix.Task
  def run(_args) do
    node = LiveNode.connect!("summarize_weekly")
    gl = Process.group_leader()

    ranges =
      :erpc.call(node, Froth.WeeklySummarizer, :pending_ranges, [@chat_id])

    case ranges do
      [] ->
        Mix.shell().info("Weekly chronicle is already current on #{node}.")

      pending ->
        Mix.shell().info(
          "Backfilling #{length(pending)} weekly chronicle chapter(s) on #{node}."
        )

        pending
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {{from_date, to_date}, index}, :ok ->
          Mix.shell().info(
            "\n[#{index}/#{length(pending)}] #{from_date} through #{to_date}\n"
          )

          code =
            "Froth.WeeklySummarizer.summarize_range(#{@chat_id}, ~D[#{from_date}], ~D[#{to_date}])"

          case :erpc.call(node, Froth.RPC, :eval, [gl, code], :infinity) do
            {:ok, summary} ->
              Mix.shell().info(
                "\nSaved weekly chapter ##{summary.id} " <>
                  "(#{summary.message_count} source messages)."
              )

              {:cont, :ok}

            {:error, reason} ->
              Mix.shell().error("Weekly chapter failed: #{inspect(reason)}")
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok -> Mix.shell().info("\nWeekly chronicle backfill complete.")
          {:error, _reason} -> System.halt(1)
        end
    end
  end
end
