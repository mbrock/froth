defmodule Froth.Repo do
  require Logger

  use Ecto.Repo,
    otp_app: :froth,
    adapter: Ecto.Adapters.Postgres

  @allow_debug_key :froth_repo_allow_debug
  @allow_debug_table :froth_repo_allow_debug
  @test_context_key :froth_repo_test_context

  @doc false
  def put_test_context(tags) when is_map(tags) do
    _ = ensure_allow_debug_table()
    Process.put(@test_context_key, format_test_context(tags))
    :ok
  end

  @doc false
  def allow_debug_context(pid \\ self()) when is_pid(pid) do
    process_dict_value(pid, @allow_debug_key) || table_allow_debug_context(pid)
  end

  @doc """
  Opt this process into the sandbox allowance chain from `parent`.

  In tests, calls `Ecto.Adapters.SQL.Sandbox.allow/3` so the current
  process can share `parent`'s DB connection. In prod/dev (non-sandbox
  pool) this is a no-op.

  `parent` can be:

    * a pid
    * a module / registered-name atom (resolved via `Process.whereis/1`)
    * a `{:via, module, key}` tuple (resolved via `GenServer.whereis/1`)
    * `nil` — no-op (useful for conditionally-set opts)

  Call from the init/1 of any OTP process that is started OUTSIDE the
  `Task.async`/`Task.Supervisor.async_nolink` `$callers` chain but
  needs DB access — typically anything started via
  `DynamicSupervisor.start_child/2` or raw `GenServer.start_link/3`.
  """
  @spec allow(pid() | atom() | {:via, module(), term()} | nil) :: :ok
  def allow(parent, label \\ "unknown")

  def allow(nil, _label), do: :ok

  def allow(parent, label) do
    if sandbox_pool?() and not shared_sandbox?() do
      pid =
        resolve_pid(parent) ||
          raise "failed to resolve parent pid #{inspect(parent)} (label: #{inspect(label)})"

      case Ecto.Adapters.SQL.Sandbox.allow(__MODULE__, pid, self()) do
        :ok ->
          debug = remember_allow_debug(pid, label)

          Logger.debug(
            "Allowed #{inspect(self())} to access repo via #{inspect(pid)} (label: #{inspect(label)}, test: #{inspect(debug.test)})"
          )

          :ok

        {:already, _kind} ->
          _debug = remember_allow_debug(pid, label)
          :ok

        reason ->
          Logger.error(
            "Failed to allow #{inspect(self())} to access repo via #{inspect(pid)} (label: #{inspect(label)}); #{inspect(reason)}"
          )

          Logger.error("Parent process state: #{inspect(Process.info(pid))}")

          raise "Failed to allow #{inspect(self())} to access repo via #{inspect(pid)} (label: #{inspect(label)}); #{inspect(reason)}"
      end
    else
      :ok
    end
  end

  # In :shared mode every process transparently routes to the shared
  # owner's proxy, so explicit allow/3 calls are both unnecessary and
  # structurally impossible (the pretended "parent" has no checkout
  # entry, so the sandbox returns :not_found). Short-circuit to :ok.
  defp shared_sandbox? do
    %{pid: pool_pid} = Ecto.Adapter.lookup_meta(__MODULE__)

    case :sys.get_state(pool_pid).mode do
      {:shared, _} -> true
      _ -> false
    end
  end

  defp sandbox_pool?, do: __MODULE__.config()[:pool] == Ecto.Adapters.SQL.Sandbox

  defp remember_allow_debug(parent_pid, label) when is_pid(parent_pid) do
    parent_debug = allow_debug_context(parent_pid)

    debug = %{
      pid: self(),
      parent_pid: parent_pid,
      label: to_string(label),
      test: inherited_test_context(parent_pid, parent_debug),
      chain: inherited_allow_chain(parent_debug, label)
    }

    Process.put(@allow_debug_key, debug)
    put_allow_debug_context(self(), debug)
    debug
  end

  defp inherited_test_context(parent_pid, parent_debug) do
    process_dict_value(parent_pid, @test_context_key) ||
      (is_map(parent_debug) && parent_debug.test)
  end

  defp inherited_allow_chain(parent_debug, label) do
    inherited =
      if is_map(parent_debug) and is_list(parent_debug.chain) do
        parent_debug.chain
      else
        []
      end

    inherited ++ [to_string(label)]
  end

  defp format_test_context(tags) do
    test_name =
      case tags[:test] do
        nil -> nil
        name -> to_string(name)
      end

    case_name =
      case tags[:case] do
        nil -> nil
        mod -> inspect(mod)
      end

    location =
      case {tags[:file], tags[:line]} do
        {file, line} when is_binary(file) and is_integer(line) ->
          "#{Path.relative_to_cwd(file)}:#{line}"

        _ ->
          nil
      end

    [case_name, test_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" when is_binary(location) -> location
      "" -> nil
      base when is_binary(location) -> "#{base} (#{location})"
      base -> base
    end
  end

  defp process_dict_value(pid, key) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, key)
      _ -> nil
    end
  end

  defp table_allow_debug_context(pid) when is_pid(pid) do
    case :ets.whereis(@allow_debug_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@allow_debug_table, pid) do
          [{^pid, debug}] -> debug
          _ -> nil
        end
    end
  end

  defp put_allow_debug_context(pid, debug) when is_pid(pid) and is_map(debug) do
    table = ensure_allow_debug_table()
    true = :ets.insert(table, {pid, debug})
    :ok
  end

  defp ensure_allow_debug_table do
    case :ets.whereis(@allow_debug_table) do
      :undefined ->
        try do
          :ets.new(@allow_debug_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @allow_debug_table
        end

      table ->
        table
    end
  end

  defp resolve_pid(nil), do: nil
  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_pid({:via, _, _} = via), do: GenServer.whereis(via)
  defp resolve_pid(_), do: nil
end
