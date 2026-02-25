defmodule Mix.Tasks.Froth.Tgcalls.Smoke do
  @shortdoc "Checks TgCalls registration on a running Froth node"
  @moduledoc """
  Queries TgCalls runtime registration from an already running Froth node.

  This task does not start the `:froth` application locally, so it avoids
  opening duplicate Telegram sessions.

  Options:
    * `--timeout` (`-t`) - status RPC timeout in milliseconds (default: 2000)
    * `--node` (`-n`) - target node (default: `RPC_NODE` or `froth@<hostname>`)
  """

  use Mix.Task

  @default_timeout 2_000

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [timeout: :integer, node: :string],
        aliases: [t: :timeout, n: :node]
      )

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    timeout = positive_opt!(opts, :timeout, @default_timeout)

    target_node =
      opts[:node] ||
        System.get_env("RPC_NODE") ||
        default_rpc_node()

    ensure_distributed_node()
    connect_target!(target_node)

    status =
      case :erpc.call(
             String.to_atom(target_node),
             Froth.Telegram.Cnode,
             :tgcalls_status,
             [timeout],
             timeout + 2_000
           ) do
        {:ok, %{} = status} -> status
        {:ok, other} -> Mix.raise("Expected map status payload, got: #{inspect(other)}")
        {:error, reason} -> Mix.raise("tgcalls_status failed: #{inspect(reason)}")
      end

    print_status(target_node, status)

    if status_ok?(status) do
      Mix.shell().info("TgCalls runtime smoke: PASS")
    else
      Mix.raise("TgCalls runtime smoke failed")
    end
  catch
    :exit, reason ->
      Mix.raise("RPC failed: #{inspect(reason)}")
  end

  defp positive_opt!(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Mix.raise("--#{key} must be a positive integer")
    end
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      :ok
    else
      node_name = :"froth_tgcalls_smoke_#{System.system_time(:millisecond)}"

      case Node.start(node_name, :shortnames) do
        {:ok, _pid} ->
          maybe_set_cookie()
          Mix.shell().info("Started distributed node #{Node.self()}")

        {:error, {:already_started, _pid}} ->
          maybe_set_cookie()
          :ok

        {:error, reason} ->
          Mix.raise("Failed to start distributed node: #{inspect(reason)}")
      end
    end
  end

  defp maybe_set_cookie do
    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil ->
          path = Path.expand("~/.erlang.cookie")
          if File.exists?(path), do: File.read!(path) |> String.trim(), else: nil

        value ->
          String.trim(value)
      end

    if is_binary(cookie) and cookie != "" do
      Node.set_cookie(String.to_atom(cookie))
    end
  end

  defp connect_target!(target_node) do
    target = String.to_atom(target_node)

    if Node.self() != target do
      if Node.connect(target) do
        Mix.shell().info("Connected to #{target}")
      else
        Mix.raise("Could not connect to #{target}. Is Froth running?")
      end
    end
  end

  defp default_rpc_node do
    host =
      case :inet.gethostname() do
        {:ok, value} -> to_string(value)
        _ -> "localhost"
      end

    "froth@#{host}"
  end

  defp status_ok?(status) when is_map(status) do
    versions = Map.get(status, "registered_versions", [])

    Map.get(status, "registration_ok") == true and
      Map.get(status, "engine_available") == true and
      is_list(versions) and
      versions != []
  end

  defp print_status(target_node, status) do
    versions =
      status
      |> Map.get("registered_versions", [])
      |> Enum.join(", ")

    Mix.shell().info("""
    tgcalls_status from #{target_node}
      registration_source: #{Map.get(status, "registration_source")}
      registration_ok: #{Map.get(status, "registration_ok")}
      engine_available: #{Map.get(status, "engine_available")}
      registered_versions: #{versions}
      max_layer: #{Map.get(status, "max_layer")}
      plugin_path: #{Map.get(status, "plugin_path")}
      registration_error: #{Map.get(status, "registration_error")}
    """)
  end
end
