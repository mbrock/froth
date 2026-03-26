defmodule Froth.Codex.TaskWatcher do
  @moduledoc """
  Watches a Codex session and mirrors its turn lifecycle into `Froth.Tasks`.
  """

  use GenServer, restart: :temporary

  alias Froth.Codex.Session, as: CodexSession

  def child_spec(opts) when is_list(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, {task_id, session_id}},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) when is_list(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    session_id = Keyword.fetch!(opts, :session_id)
    session_module = Keyword.get(opts, :session_module, CodexSession)

    GenServer.start_link(__MODULE__, %{
      task_id: task_id,
      session_id: session_id,
      session_module: session_module
    })
  end

  @impl true
  def init(%{task_id: task_id, session_id: session_id, session_module: session_module}) do
    with :ok <- session_module.subscribe(session_id),
         {:ok, snapshot} <- session_module.snapshot(session_id) do
      {session_pid, session_ref} = monitor_session(session_module, session_id)

      {:ok,
       %{
         task_id: task_id,
         session_id: session_id,
         session_module: session_module,
         session_pid: session_pid,
         session_ref: session_ref,
         saw_working?: working_snapshot?(snapshot),
         last_entry_sequence: last_entry_sequence(snapshot)
       }}
    else
      {:error, reason} -> {:stop, reason}
      other -> {:stop, {:init_failed, other}}
    end
  end

  @impl true
  def handle_info({:codex_session_updated, session_id}, %{session_id: session_id} = state) do
    case state.session_module.snapshot(session_id) do
      {:ok, snapshot} ->
        new_entries = new_entries(snapshot, state.last_entry_sequence)
        now_working? = working_snapshot?(snapshot)
        saw_working? = state.saw_working? or now_working? or saw_working_entry?(new_entries)

        completed_turn? =
          not now_working? and saw_completed_turn_entry?(new_entries)

        idle_after_turn? = state.saw_working? and not now_working?
        last_entry_sequence = last_entry_sequence(snapshot)

        cond do
          error_snapshot?(snapshot) ->
            Froth.Tasks.fail(state.task_id, failure_reason(snapshot))
            {:stop, :normal, state}

          idle_after_turn? or completed_turn? ->
            Froth.Tasks.complete(state.task_id, completion_metadata(snapshot, state.session_id))
            {:stop, :normal, state}

          true ->
            {:noreply,
             %{state | saw_working?: saw_working?, last_entry_sequence: last_entry_sequence}}
        end

      {:error, reason} ->
        Froth.Tasks.fail(state.task_id, snapshot_failure_reason(reason))
        {:stop, :normal, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{session_ref: ref, session_pid: pid} = state
      ) do
    Froth.Tasks.fail(state.task_id, down_reason(reason))
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp monitor_session(session_module, session_id) do
    case session_module.whereis(session_id) do
      pid when is_pid(pid) ->
        {pid, Process.monitor(pid)}

      _ ->
        {nil, nil}
    end
  end

  defp working_snapshot?(snapshot) when is_map(snapshot) do
    active_turn_id = Map.get(snapshot, :active_turn_id) || Map.get(snapshot, "active_turn_id")
    is_binary(active_turn_id)
  end

  defp error_snapshot?(snapshot) when is_map(snapshot) do
    status = Map.get(snapshot, :status) || Map.get(snapshot, "status")
    status == :error
  end

  defp last_entry_sequence(snapshot) when is_map(snapshot) do
    snapshot
    |> snapshot_entries()
    |> Enum.map(&entry_sequence/1)
    |> Enum.max(fn -> 0 end)
  end

  defp new_entries(snapshot, last_entry_sequence)
       when is_map(snapshot) and is_integer(last_entry_sequence) do
    Enum.filter(snapshot_entries(snapshot), &(entry_sequence(&1) > last_entry_sequence))
  end

  defp saw_working_entry?(entries) when is_list(entries) do
    Enum.any?(entries, &entry_body_starts_with?(&1, "working"))
  end

  defp saw_completed_turn_entry?(entries) when is_list(entries) do
    Enum.any?(entries, &entry_body_starts_with?(&1, "turn "))
  end

  defp completion_metadata(snapshot, session_id) when is_map(snapshot) do
    thread_id = Map.get(snapshot, :thread_id) || Map.get(snapshot, "thread_id")

    %{session_id: session_id, thread_id: thread_id}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp failure_reason(snapshot) when is_map(snapshot) do
    snapshot
    |> last_error_body()
    |> case do
      body when is_binary(body) and body != "" -> body
      _ -> "Codex session failed"
    end
    |> String.slice(0, 200)
  end

  defp snapshot_failure_reason(reason) do
    "Codex session snapshot failed: #{inspect(reason)}"
    |> String.slice(0, 200)
  end

  defp down_reason(reason) do
    "Codex session exited: #{inspect(reason)}"
    |> String.slice(0, 200)
  end

  defp last_error_body(snapshot) when is_map(snapshot) do
    snapshot
    |> snapshot_entries()
    |> Enum.reverse()
    |> Enum.find_value(&error_entry_body/1)
  end

  defp snapshot_entries(snapshot) when is_map(snapshot) do
    Map.get(snapshot, :entries) || Map.get(snapshot, "entries") || []
  end

  defp entry_sequence(entry) when is_map(entry) do
    Map.get(entry, :sequence) || Map.get(entry, "sequence") || 0
  end

  defp entry_body_starts_with?(entry, prefix) when is_map(entry) and is_binary(prefix) do
    body = Map.get(entry, :body) || Map.get(entry, "body")
    is_binary(body) and String.starts_with?(body, prefix)
  end

  defp error_entry_body(entry) when is_map(entry) do
    kind = Map.get(entry, :kind) || Map.get(entry, "kind")
    body = Map.get(entry, :body) || Map.get(entry, "body")

    if kind in [:error, "error"] and is_binary(body) and body != "" do
      body
    end
  end
end
