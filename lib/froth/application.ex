defmodule Froth.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        FrothWeb.Telemetry,
        Froth.Repo,
        {Oban, Application.fetch_env!(:froth, Oban)},
        {Finch, name: Froth.Finch},
        Froth.Dataset,
        {Phoenix.PubSub, name: Froth.PubSub},
        Froth.Telegram,
        Froth.Telegram.Bots,
        {Registry, keys: :unique, name: Froth.Agent.Registry},
        {Task.Supervisor, name: Froth.Agent.TaskSupervisor}
      ] ++
        Enum.map(Application.fetch_env!(:froth, Froth.Telegram.Bot), fn bot_opts ->
          {Froth.Telegram.Bot, bot_opts}
        end) ++
        [
          {Registry, keys: :unique, name: Froth.Codex.SessionRegistry},
          {DynamicSupervisor, name: Froth.Codex.SessionSupervisor, strategy: :one_for_one},
          {Registry, keys: :unique, name: Froth.Tasks.Registry},
          Froth.Tasks.EvalSessions,
          {DynamicSupervisor, name: Froth.Tasks.Supervisor, strategy: :one_for_one},
          {Task.Supervisor, name: Froth.TaskSupervisor},
          {DNSCluster, query: Application.get_env(:froth, :dns_cluster_query) || :ignore},
          # Start a worker by calling: Froth.Worker.start_link(arg)
          # {Froth.Worker, arg},
          # Start to serve requests, typically the last entry
          FrothWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Froth.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        sd_notify_ready()
        ok

      error ->
        error
    end
  end

  defp sd_notify_ready do
    case System.get_env("NOTIFY_SOCKET") do
      nil ->
        :ok

      path ->
        addr =
          if String.starts_with?(path, "@"),
            do: %{family: :local, path: <<0, String.slice(path, 1..-1//1)::binary>>},
            else: %{family: :local, path: path}

        with {:ok, sock} <- :socket.open(:local, :dgram, :default),
             :ok <- :socket.sendto(sock, "READY=1", addr) do
          :socket.close(sock)
        end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FrothWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
