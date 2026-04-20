defmodule Froth.Telegram.BotRuntime do
  @moduledoc """
  Per-bot supervisor tree.

  Owns the bot worker process plus its private cycle supervisor so bot
  shutdown and restart semantics cover the whole subtree.
  """

  use Supervisor

  alias Froth.Telegram.Bot

  @bot_child_id :bot
  @cycles_sup_child_id :cycles_sup
  @runtime_marker :froth_bot_runtime

  def child_spec(opts) when is_map(opts), do: child_spec(Map.to_list(opts))

  def child_spec(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.put(@runtime_marker, true)
    worker_opts = Keyword.delete(opts, :name)

    children = [
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one},
        id: @cycles_sup_child_id
      ),
      Supervisor.child_spec({Bot, Keyword.put(worker_opts, :runtime_ref, self())},
        id: @bot_child_id
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @spec bot_pid(pid() | atom() | {:via, module(), term()}) :: pid() | nil
  def bot_pid(ref) do
    case resolve_runtime_or_worker(ref) do
      {:runtime, runtime_pid} ->
        child_pid(runtime_pid, @bot_child_id)

      {:worker, worker_pid} ->
        worker_pid

      :error ->
        nil
    end
  end

  @spec start_cycle_runtime(pid() | atom() | {:via, module(), term()}, keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, :bot_not_running}
  def start_cycle_runtime(ref, runtime_opts) when is_list(runtime_opts) do
    with {:ok, runtime_pid} <- runtime_pid(ref),
         bot_pid when is_pid(bot_pid) <- runtime_opts[:bot_pid] || bot_pid(ref),
         bot_config when is_map(bot_config) <-
           runtime_opts[:bot_config] || GenServer.call(bot_pid, :snapshot),
         cycles_sup when is_pid(cycles_sup) <- child_pid(runtime_pid, @cycles_sup_child_id) do
      runtime_opts =
        runtime_opts
        |> Keyword.put_new(:bot_pid, bot_pid)
        |> Keyword.put_new(:bot_config, bot_config)
        |> Keyword.put_new(:bot_id, bot_config.id)

      DynamicSupervisor.start_child(cycles_sup, {Froth.Agent.CycleRuntime, runtime_opts})
    else
      _ -> {:error, :bot_not_running}
    end
  end

  defp runtime_pid(ref) do
    case resolve_runtime_or_worker(ref) do
      {:runtime, runtime_pid} -> {:ok, runtime_pid}
      {:worker, worker_pid} -> {:ok, GenServer.call(worker_pid, :runtime_ref)}
      :error -> {:error, :bot_not_running}
    end
  catch
    :exit, _reason -> {:error, :bot_not_running}
  end

  defp resolve_runtime_or_worker(pid) when is_pid(pid) do
    if process_dict_value(pid, @runtime_marker) == true, do: {:runtime, pid}, else: {:worker, pid}
  end

  defp resolve_runtime_or_worker(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> resolve_runtime_or_worker(pid)
      nil -> :error
    end
  end

  defp resolve_runtime_or_worker({:via, _, _} = via) do
    case GenServer.whereis(via) do
      pid when is_pid(pid) -> resolve_runtime_or_worker(pid)
      nil -> :error
    end
  end

  defp child_pid(runtime_pid, child_id) when is_pid(runtime_pid) do
    case Supervisor.which_children(runtime_pid) do
      children when is_list(children) ->
        Enum.find_value(children, fn
          {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
          _ -> nil
        end)

      _ ->
        nil
    end
  catch
    :exit, _reason -> nil
  end

  defp process_dict_value(pid, key) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, key)
      _ -> nil
    end
  end
end
