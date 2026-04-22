defmodule Froth.Cluster do
  @moduledoc false

  @default_full_nodes [:froth@igloo, :froth@swa, :"froth@Mikaels-Mac-mini"]
  @default_coordinator_node :froth@igloo
  @default_timeout_ms 30_000
  @node_split ~r/[\s,]+/
  @valid_node_name ~r/^[A-Za-z][A-Za-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9._-]*$/
  @valid_host_name ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  def topologies do
    if Node.alive?() do
      hosts =
        configured_nodes()
        |> Enum.reject(&(&1 == Node.self()))

      if hosts == [] do
        []
      else
        [
          tailscale_epmd: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: hosts, timeout: topology_timeout_ms()]
          ]
        ]
      end
    else
      []
    end
  end

  def configured_nodes(
        value \\ System.get_env("FROTH_CLUSTER_NODES"),
        opts \\ []
      ) do
    case normalize_nodes_value(value) do
      :default -> default_nodes(opts)
      :disabled -> []
      nodes -> nodes
    end
  end

  def coordinator_node(value \\ System.get_env("FROTH_COORDINATOR_NODE")) do
    case normalize_node_value(value) do
      nil -> @default_coordinator_node
      node -> node
    end
  end

  def local_node_name do
    case explicit_local_node_name() do
      nil -> "froth@" <> short_hostname()
      node -> Atom.to_string(node)
    end
  end

  def rpc_target_node_name do
    System.get_env("RPC_NODE") || local_node_name()
  end

  def rpc_target_node do
    rpc_target_node_name()
    |> String.to_atom()
  end

  defp default_nodes(opts) do
    case Keyword.get(opts, :node_role, node_role()) do
      :worker -> [coordinator_node(Keyword.get(opts, :coordinator_node))]
      _ -> @default_full_nodes
    end
  end

  defp normalize_nodes_value(nil), do: :default

  defp normalize_nodes_value(value) when is_binary(value) do
    case String.trim(value) |> String.downcase() do
      "" -> :default
      "default" -> :default
      "off" -> :disabled
      "false" -> :disabled
      "none" -> :disabled
      _ -> parse_node_list(value)
    end
  end

  defp parse_node_list(value) do
    # Cluster peers come from operator-controlled env vars at boot, not request input.
    value
    |> String.split(@node_split, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@valid_node_name, &1))
    |> Enum.uniq()
    |> Enum.map(&String.to_atom/1)
  end

  defp normalize_node_value(nil), do: nil

  defp normalize_node_value(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@valid_node_name, value) do
      String.to_atom(value)
    else
      nil
    end
  end

  defp normalize_node_value(value) when is_atom(value), do: value
  defp normalize_node_value(_value), do: nil

  defp node_role do
    case Application.get_env(:froth, :node_role, :full) do
      :worker -> :worker
      _ -> :full
    end
  end

  defp short_hostname do
    case :inet.gethostname() do
      {:ok, hostname} ->
        List.to_string(hostname)

      _ ->
        "localhost"
    end
  end

  defp explicit_local_node_name do
    case normalize_node_value(System.get_env("FROTH_NODE_NAME")) do
      nil ->
        explicit_local_node_name_from_host()

      node ->
        node
    end
  end

  defp explicit_local_node_name_from_host do
    case System.get_env("FROTH_NODE_HOST") do
      host when is_binary(host) ->
        host = String.trim(host)

        if host != "" and Regex.match?(@valid_host_name, host) do
          String.to_atom("froth@" <> host)
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp topology_timeout_ms do
    case System.get_env("FROTH_CLUSTER_TIMEOUT_MS") do
      nil ->
        @default_timeout_ms

      value ->
        case Integer.parse(value) do
          {timeout_ms, ""} when timeout_ms > 0 -> timeout_ms
          _ -> @default_timeout_ms
        end
    end
  end
end
