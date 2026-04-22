defmodule Mix.Tasks.Froth.Telegram.Auth do
  @moduledoc """
  Authenticate a Telegram session via RPC to the running Froth node.

      mix froth.telegram.auth --session mbrockman
      mix froth.telegram.auth --session mbrockman --print-updates all
      mix froth.telegram.auth --session my-bot --use-bot

  By default this prefers user login (`--user`) so a terminal wrapper can drive
  phone/code/2FA auth without accidentally attempting bot-token auth.
  """
  @shortdoc "Authenticate a Telegram session via RPC"

  use Mix.Task

  alias Froth.Mix.LiveNode

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          session: :string,
          print_updates: :string,
          use_bot: :boolean,
          user: :boolean
        ]
      )

    if invalid != [] do
      abort("Unknown arguments: #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    end

    session_id =
      Keyword.get(opts, :session) ||
        abort("--session SESSION_ID is required")

    print_updates = parse_print_updates!(Keyword.get(opts, :print_updates))
    use_bot = resolve_use_bot(opts)

    node = LiveNode.connect!("telegram_auth")
    gl = Process.group_leader()

    Mix.shell().info(
      "Authenticating Telegram session #{session_id} on #{node}..."
    )

    case :erpc.call(
           node,
           Froth.RPC,
           :eval,
           [gl, rpc_code(session_id, use_bot, print_updates)],
           :infinity
         ) do
      {:ok, :ready} ->
        Mix.shell().info("Telegram session #{session_id} is ready.")

      other ->
        abort("Unexpected response: #{inspect(other, limit: :infinity)}")
    end
  end

  defp rpc_code(session_id, use_bot, print_updates) do
    "Froth.Telegram.Auth.run_blocking(" <>
      "#{inspect(session_id)}, " <>
      "use_bot: #{inspect(use_bot)}, " <>
      "print_updates: #{inspect(print_updates)})"
  end

  defp resolve_use_bot(opts) do
    cond do
      Keyword.get(opts, :user, false) -> false
      Keyword.has_key?(opts, :use_bot) -> Keyword.fetch!(opts, :use_bot)
      true -> false
    end
  end

  defp parse_print_updates!(nil), do: :important
  defp parse_print_updates!("important"), do: :important
  defp parse_print_updates!("all"), do: :all
  defp parse_print_updates!("false"), do: false

  defp parse_print_updates!(value) do
    abort(
      "--print-updates must be one of: important, all, false (got #{inspect(value)})"
    )
  end

  defp abort(msg) do
    Mix.shell().error(msg)
    System.halt(1)
  end
end
