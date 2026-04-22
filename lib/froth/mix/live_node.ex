defmodule Froth.Mix.LiveNode do
  @moduledoc false

  @spec connect!(atom() | String.t()) :: node()
  def connect!(client_prefix) when is_atom(client_prefix) do
    connect!(Atom.to_string(client_prefix))
  end

  def connect!(client_prefix) when is_binary(client_prefix) do
    node = Froth.Cluster.rpc_target_node()
    ensure_local_node!(client_prefix)

    unless Node.connect(node) do
      Mix.raise("Could not connect to #{node}. Is Froth running?")
    end

    node
  end

  defp ensure_local_node!(client_prefix) do
    if Node.alive?() do
      Node.self()
    else
      cookie = read_cookie!()
      name = local_node_name(client_prefix)

      case Node.start(name, :shortnames) do
        {:ok, _pid} ->
          Node.set_cookie(String.to_atom(cookie))
          name

        {:error, {:already_started, _pid}} ->
          Node.set_cookie(String.to_atom(cookie))
          Node.self()

        {:error, reason} ->
          Mix.raise(
            "Failed to start distributed node #{name}: #{inspect(reason)}"
          )
      end
    end
  end

  defp local_node_name(client_prefix) do
    sanitized =
      client_prefix
      |> String.trim()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> case do
        "" -> "froth"
        value -> value
      end

    String.to_atom("#{sanitized}_#{System.pid()}")
  end

  defp read_cookie! do
    case System.get_env("ERLANG_COOKIE") do
      value when is_binary(value) and value != "" ->
        String.trim(value)

      _ ->
        path = Path.expand("~/.erlang.cookie")

        if File.exists?(path) do
          path
          |> File.read!()
          |> String.trim()
        else
          Mix.raise(
            "Could not find an Erlang cookie in ERLANG_COOKIE or ~/.erlang.cookie"
          )
        end
    end
  end
end
