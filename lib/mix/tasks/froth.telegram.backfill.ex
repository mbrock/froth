defmodule Mix.Tasks.Froth.Telegram.Backfill do
  @moduledoc """
  Backfill Telegram history via RPC to the running node.

  By default, infers the session id if there is exactly one enabled user session
  (a Telegram session with a phone number and no bot token).

      mix froth.telegram.backfill
      mix froth.telegram.backfill --session mbrockman
      mix froth.telegram.backfill --session mbrockman --chat-id -1001234567890
      mix froth.telegram.backfill --session mbrockman --chat-limit 500
      mix froth.telegram.backfill --session mbrockman --chat-id -1001234567890 --verbose
  """
  @shortdoc "Backfill Telegram history via RPC"

  use Mix.Task

  @default_node "froth@igloo"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [session: :string, chat_id: :integer, chat_limit: :integer, verbose: :boolean]
      )

    if invalid != [] do
      abort("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    end

    chat_id = Keyword.get(opts, :chat_id)
    chat_limit = Keyword.get(opts, :chat_limit, 200)
    verbose = Keyword.get(opts, :verbose, false)

    if chat_limit <= 0 do
      abort("--chat-limit must be a positive integer")
    end

    node = connect!()
    gl = Process.group_leader()
    session_id = Keyword.get(opts, :session) || resolve_session_id(node, gl)

    if chat_id do
      Mix.shell().info(
        "Backfilling chat #{chat_id} from Telegram session #{session_id} on #{node}..."
      )

      code =
        "Froth.Telegram.Sync.backfill_chat(" <>
          "#{inspect(session_id)}, #{chat_id}, verbose: #{verbose})"

      case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
        count when is_integer(count) ->
          Mix.shell().info("Stored #{count} messages for chat #{chat_id}")

        other ->
          Mix.shell().error("Unexpected response: #{inspect(other)}")
      end
    else
      Mix.shell().info(
        "Backfilling up to #{chat_limit} chats from Telegram session #{session_id} on #{node}..."
      )

      code =
        "Froth.Telegram.Sync.backfill(" <>
          "#{inspect(session_id)}, chat_limit: #{chat_limit}, verbose: #{verbose})"

      case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
        {:ok, %{chats: chats, messages: messages}} ->
          Mix.shell().info("Stored #{messages} messages across #{chats} chats")

        other ->
          Mix.shell().error("Unexpected response: #{inspect(other)}")
      end
    end
  end

  defp resolve_session_id(node, gl) do
    code = """
    import Ecto.Query

    Froth.Repo.all(
      from(s in Froth.Telegram.SessionConfig,
        where: s.enabled == true and not is_nil(s.phone_number) and is_nil(s.bot_token),
        select: s.id
      ),
      log: false
    )
    """

    case :erpc.call(node, Froth.RPC, :eval, [gl, code]) do
      [session_id] when is_binary(session_id) ->
        session_id

      [] ->
        abort(
          "No enabled user Telegram sessions found. Pass --session SESSION_ID to select one explicitly."
        )

      ids when is_list(ids) ->
        abort(
          "Multiple enabled user Telegram sessions found: #{Enum.join(ids, ", ")}. " <>
            "Pass --session SESSION_ID."
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

    Node.start(:"telegram_backfill_#{System.pid()}", name_domain: :shortnames)
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
