defmodule Froth.Tasks.Shell do
  @moduledoc """
  A GenServer that owns a shell Port process. One per shell command,
  started under Froth.Tasks.Supervisor (DynamicSupervisor) and registered
  in Froth.Tasks.Registry by task_id.

  Stays alive after the port exits so callers can still query it.
  Stops itself after an idle timeout.
  """

  use GenServer, restart: :temporary

  require Logger

  @shell_await_ms 3_000
  @idle_timeout_ms :timer.minutes(10)

  # --- Public API ---

  def start_link(opts) when is_list(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    command = Keyword.fetch!(opts, :command)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    GenServer.start_link(
      __MODULE__,
      %{task_id: task_id, command: command, working_dir: working_dir},
      name: via(task_id)
    )
  end

  def task_id(pid) when is_pid(pid), do: GenServer.call(pid, :task_id)

  def await(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    GenServer.call(pid, {:await, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, _ -> :running
  end

  def send_input(task_id, input) when is_binary(task_id) and is_binary(input) do
    GenServer.call(via(task_id), {:send_input, input})
  end

  def send_signal(task_id, signal) when is_binary(task_id) do
    GenServer.call(via(task_id), {:send_signal, signal})
  end

  def alive?(task_id) when is_binary(task_id) do
    case Registry.lookup(Froth.Tasks.Registry, task_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # --- Starting a shell from tool execution ---

  def run_shell(command, opts \\ []) do
    task_id = Froth.Tasks.generate_id("shell")
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    telegram = Keyword.get(opts, :telegram)

    {:ok, _task} =
      Froth.Tasks.create(%{
        task_id: task_id,
        type: "shell",
        label: command,
        metadata: %{working_dir: working_dir}
      })

    if telegram do
      Froth.Tasks.link_telegram(task_id, telegram[:bot_id],
        chat_id: telegram[:chat_id],
        message_id: telegram[:message_id]
      )
    end

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Froth.Tasks.Supervisor,
        {__MODULE__, [task_id: task_id, command: command, working_dir: working_dir]}
      )

    case await(pid, @shell_await_ms) do
      {:completed, exit_code, output} ->
        {:ok, format_completed(task_id, command, exit_code, output)}

      :running ->
        {:ok,
         "Started shell task #{task_id}: `#{command}` (still running, use task_output to check progress)"}
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%{task_id: task_id, command: command, working_dir: working_dir}) do
    port =
      Port.open(
        {:spawn_executable, "/bin/bash"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:cd, working_dir},
          {:args, ["-c", command]}
        ]
      )

    {:ok, os_pid} = Keyword.fetch(Port.info(port), :os_pid)

    Logger.info(
      event: :shell_started,
      task_id: task_id,
      command: command,
      os_pid: os_pid,
      working_dir: working_dir
    )

    Froth.Tasks.start(task_id)

    {:ok,
     %{
       task_id: task_id,
       port: port,
       os_pid: os_pid,
       exit_status: nil,
       output_chunks: [],
       waiters: []
     }}
  end

  @impl true
  def handle_call(:task_id, _from, state) do
    {:reply, state.task_id, state}
  end

  def handle_call({:await, timeout_ms}, from, %{exit_status: nil} = state) do
    timer = Process.send_after(self(), {:await_timeout, from}, timeout_ms)
    {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}
  end

  def handle_call({:await, _timeout_ms}, _from, state) do
    output = state.output_chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {:reply, {:completed, state.exit_status, output}, state}
  end

  def handle_call({:send_input, input}, _from, %{exit_status: nil} = state) do
    Port.command(state.port, input)
    Froth.Tasks.append(state.task_id, "stdin", input)
    {:reply, :ok, state}
  end

  def handle_call({:send_input, _input}, _from, state) do
    {:reply, {:error, :exited}, state}
  end

  def handle_call({:send_signal, signal}, _from, state) do
    signal_str = to_string(signal)

    Logger.info(
      event: :shell_signal,
      task_id: state.task_id,
      signal: signal_str,
      os_pid: state.os_pid
    )

    System.cmd("kill", ["-#{signal_str}", "#{state.os_pid}"])
    Froth.Tasks.append(state.task_id, "signal", signal_str)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Froth.Tasks.append_output(state.task_id, data)
    {:noreply, %{state | output_chunks: [data | state.output_chunks]}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.info(
      event: :shell_exited,
      task_id: state.task_id,
      exit_code: code,
      os_pid: state.os_pid
    )

    Froth.Tasks.complete(state.task_id, %{exit_code: code})
    state = %{state | exit_status: code}

    output = state.output_chunks |> Enum.reverse() |> IO.iodata_to_binary()

    for {from, timer} <- state.waiters do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:completed, code, output})
    end

    Process.send_after(self(), :idle_shutdown, @idle_timeout_ms)
    {:noreply, %{state | waiters: []}}
  end

  def handle_info({:await_timeout, from}, state) do
    state = %{state | waiters: Enum.reject(state.waiters, fn {f, _} -> f == from end)}
    GenServer.reply(from, :running)
    {:noreply, state}
  end

  def handle_info(:idle_shutdown, state) do
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Shell #{state.task_id} unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  defp via(task_id) do
    {:via, Registry, {Froth.Tasks.Registry, task_id}}
  end

  defp format_completed(task_id, command, exit_code, output) do
    trimmed = String.trim(output)
    exit_str = if exit_code in [0, nil], do: "", else: " (exit code: #{exit_code})"

    if String.length(trimmed) > 4000 do
      "Shell #{task_id}: `#{command}`#{exit_str}\n#{String.slice(trimmed, 0, 4000)}\n... (truncated, use task_output for full output)"
    else
      "Shell #{task_id}: `#{command}`#{exit_str}\n#{trimmed}"
    end
  end
end
