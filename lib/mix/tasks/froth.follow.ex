defmodule Mix.Tasks.Froth.Follow do
  @moduledoc "Connect to the running node and follow PubSub broadcasts."
  @shortdoc "Follow PubSub broadcasts on the running node"

  use Mix.Task

  @default_node "froth@igloo"

  @impl Mix.Task
  def run(args) do
    node =
      System.get_env("RPC_NODE", @default_node)
      |> String.to_atom()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"follow_#{System.pid()}", :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      Mix.shell().error("Could not connect to #{node}")
      System.halt(1)
    end

    Application.ensure_all_started(:phoenix_pubsub)

    {:ok, _} =
      Supervisor.start_link([{Phoenix.PubSub, name: Froth.PubSub}], strategy: :one_for_one)

    topics = if args == [], do: ["notes"], else: args

    Enum.each(topics, fn topic ->
      Phoenix.PubSub.subscribe(Froth.PubSub, topic)
    end)

    Mix.shell().info("Connected to #{node}")
    Mix.shell().info("Subscribed to: #{Enum.join(topics, ", ")}\n")

    loop()
  end

  defp loop do
    receive do
      msg ->
        ts = DateTime.utc_now() |> Calendar.strftime("%H:%M:%S.%f") |> String.slice(0, 12)
        IO.write([IO.ANSI.faint(), ts, IO.ANSI.reset(), " "])
        IO.inspect(msg, pretty: true, limit: 10, width: 120)
        IO.puts("")
    end

    loop()
  end
end
