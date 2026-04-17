defmodule Froth.Repo do
  require Logger
  use Ecto.Repo,
    otp_app: :froth,
    adapter: Ecto.Adapters.Postgres

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
      pid = resolve_pid(parent) || raise "failed to resolve parent pid #{inspect(parent)} (label: #{inspect(label)})"

      case Ecto.Adapters.SQL.Sandbox.allow(__MODULE__, pid, self()) do
        :ok ->
          Logger.debug(
            "Allowed #{inspect(self())} to access repo via #{inspect(pid)} (label: #{inspect(label)})"
          )

          :ok

        {:already, _kind} ->
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

  defp resolve_pid(nil), do: nil
  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_pid({:via, _, _} = via), do: GenServer.whereis(via)
  defp resolve_pid(_), do: nil
end
