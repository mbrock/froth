defmodule Mix.Tasks.Froth.Context do
  @moduledoc """
  Print Charlie's full prompt context (system + user parts) to stdout,
  exactly as the LLM would see it.

      mix froth.context
      mix froth.context --messages 20
      mix froth.context --only-messages
      mix froth.context --no-trivial
  """
  @shortdoc "Print Charlie's prompt context via RPC"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [messages: :integer, only_messages: :boolean, no_trivial: :boolean]
      )

    message_limit = Keyword.get(opts, :messages)
    only_messages = Keyword.get(opts, :only_messages, false)
    no_trivial = Keyword.get(opts, :no_trivial, false)

    node = connect!()

    {system_prompt, parts} =
      :erpc.call(node, fn ->
        config = Froth.Telegram.Charlie.default_config()
        chat_id = -1_003_690_254_489

        limit = message_limit || config.recent_message_limit

        opts = [
          telegram_session_id: config.session_id,
          bot_id: config.id,
          chronicle_dir: if(only_messages, do: nil, else: config.chronicle_dir),
          recent_message_limit: limit,
          only_nontrivial: no_trivial
        ]

        parts = Froth.Telegram.BotContext.render_parts(chat_id, opts)
        system_prompt = config.system_prompt_fun.(chat_id, config)
        {system_prompt, parts}
      end)

    unless only_messages, do: IO.puts(system_prompt)

    parts
    |> Enum.intersperse("\n")
    |> Enum.each(&IO.puts/1)
  end

  defp connect! do
    node = Froth.Cluster.rpc_target_node()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"froth_context_#{System.pid()}", name_domain: :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      Mix.shell().error("Could not connect to #{node}")
      System.halt(1)
    end

    node
  end
end
