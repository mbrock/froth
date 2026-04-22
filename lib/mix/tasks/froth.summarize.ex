defmodule Mix.Tasks.Froth.Summarize do
  @moduledoc """
  Run the summarizer via RPC to the running node.

  With `--date`, summarizes that one UTC day.
  Without `--date`, summarizes each missing UTC day from the latest stored daily
  summary up to yesterday.
  """
  @shortdoc "Summarize a chat day via RPC"

  use Mix.Task

  alias Froth.Mix.LiveNode

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: [date: :string])

    if invalid != [] do
      abort("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    end

    node = LiveNode.connect!("summarize")
    gl = Process.group_leader()
    chat_id = resolve_chat_id(node, gl)

    result =
      case Keyword.get(opts, :date) do
        nil ->
          summarize_pending_days(node, gl, chat_id)

        date_str ->
          summarize_one_day(node, gl, chat_id, parse_date!(date_str))
      end

    case result do
      :ok -> :ok
      {:error, reason} -> abort("Summarizer failed: #{inspect(reason)}")
    end
  end

  defp resolve_chat_id(node, gl) do
    code = """
    import Ecto.Query
    Froth.Repo.all(
      from(s in Froth.ChatSummary, select: s.chat_id, distinct: true),
      log: false
    )
    """

    case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
      [chat_id] ->
        chat_id

      [] ->
        abort("No existing summaries found. Cannot determine chat_id.")

      ids when is_list(ids) ->
        abort(
          "Multiple chats have summaries: #{Enum.join(ids, ", ")}. " <>
            "Expected exactly one."
        )
    end
  end

  defp summarize_pending_days(node, gl, chat_id) do
    dates =
      :erpc.call(node, Froth.Summarizer, :pending_summary_dates, [chat_id])

    case dates do
      [] ->
        Mix.shell().info(
          "No pending days to summarize for chat #{chat_id} on #{node}. " <>
            "Latest completed UTC day is already covered."
        )

        :ok

      pending_dates ->
        first_date = pending_dates |> hd() |> Date.to_iso8601()
        last_date = pending_dates |> List.last() |> Date.to_iso8601()

        Mix.shell().info(
          "Summarizing #{length(pending_dates)} pending day(s) for chat #{chat_id} " <>
            "from #{first_date} through #{last_date} on #{node}..."
        )

        Enum.reduce_while(pending_dates, :ok, fn date, :ok ->
          case summarize_one_day(node, gl, chat_id, date) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp summarize_one_day(node, gl, chat_id, %Date{} = date) do
    date_str = Date.to_iso8601(date)

    Mix.shell().info(
      "Summarizing chat #{chat_id} for #{date_str} on #{node}..."
    )

    code = "Froth.Summarizer.summarize_day(#{chat_id}, ~D[#{date_str}])"

    case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
      {:ok, summary} ->
        Mix.shell().info("\nSaved summary ##{summary.id}")
        :ok

      {:error, :no_messages} ->
        Mix.shell().info(
          "No messages found for chat #{chat_id} on #{date_str}; skipping."
        )

        :ok

      {:error, reason} ->
        Mix.shell().error("Error summarizing #{date_str}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_date!(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> abort("Invalid date: #{str}. Use YYYY-MM-DD format.")
    end
  end

  defp abort(msg) do
    Mix.shell().error(msg)
    System.halt(1)
  end
end
