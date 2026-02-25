defmodule Mix.Tasks.Froth.Summarize do
  @moduledoc "Run the summarizer for a given date via RPC to the running node."
  @shortdoc "Summarize a chat day via RPC"

  use Mix.Task

  @default_node "froth@igloo"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args, strict: [date: :string])

    date_str =
      case Keyword.get(opts, :date) do
        nil ->
          Date.utc_today() |> Date.to_iso8601()

        str ->
          case Date.from_iso8601(str) do
            {:ok, _} -> str
            {:error, _} -> abort("Invalid date: #{str}. Use YYYY-MM-DD format.")
          end
      end

    node = connect!()
    gl = Process.group_leader()

    chat_id = resolve_chat_id(node, gl)

    Mix.shell().info("Summarizing chat #{chat_id} for #{date_str} on #{node}...")

    code = "Froth.Summarizer.summarize_day(#{chat_id}, ~D[#{date_str}])"

    case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
      {:ok, summary} ->
        Mix.shell().info("\nSaved summary ##{summary.id}")

      {:error, :no_messages} ->
        Mix.shell().error("No messages found for chat #{chat_id} on #{date_str}")

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
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

  defp connect! do
    node =
      System.get_env("RPC_NODE", @default_node)
      |> String.to_atom()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"summarize_#{System.pid()}", :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      abort("Could not connect to #{node}")
    end

    node
  end

  defp abort(msg) do
    Mix.shell().error(msg)
    System.halt(1)
  end
end
