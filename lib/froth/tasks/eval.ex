defmodule Froth.Tasks.Eval do
  @moduledoc """
  A GenServer that evaluates Elixir code. One per evaluation,
  started under Froth.Tasks.Supervisor (DynamicSupervisor) and registered
  in Froth.Tasks.Registry by task_id.

  IO output is captured via a custom group leader that writes to task_events.
  Stays alive after completion so callers can query the result.
  """

  use GenServer, restart: :temporary

  alias Froth.Telemetry.Span

  @eval_await_ms 3_000
  @idle_timeout_ms :timer.minutes(10)

  # --- Public API ---

  def start_link(opts) when is_list(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    code = Keyword.fetch!(opts, :code)
    topic = Keyword.get(opts, :topic)
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(
      __MODULE__,
      %{task_id: task_id, code: code, topic: topic, session_id: session_id},
      name: via(task_id)
    )
  end

  def task_id(pid) when is_pid(pid), do: GenServer.call(pid, :task_id)

  def await(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    GenServer.call(pid, {:await, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, _ -> :running
  end

  def stop_eval(task_id) when is_binary(task_id) do
    GenServer.call(via(task_id), :stop_eval)
  catch
    :exit, _ -> {:error, :not_running}
  end

  def alive?(task_id) when is_binary(task_id) do
    case Registry.lookup(Froth.Tasks.Registry, task_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # --- Starting an eval from tool execution ---

  def run_eval(code, opts \\ []) do
    task_id = Froth.Tasks.generate_id("eval")
    telegram = Keyword.get(opts, :telegram)
    topic = Keyword.get(opts, :topic)
    requested_session_id = Keyword.get(opts, :session_id)
    {session_id, _created?} = Froth.Tasks.EvalSessions.ensure_session(requested_session_id)

    {:ok, _task} =
      Froth.Tasks.create(%{
        task_id: task_id,
        type: "eval",
        label: String.slice(code, 0, 100),
        metadata: %{code: code, session_id: session_id}
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
        {__MODULE__, [task_id: task_id, code: code, topic: topic, session_id: session_id]}
      )

    case await(pid, @eval_await_ms) do
      {:completed, result_text, is_error} ->
        if is_error, do: {:error, result_text}, else: {:ok, result_text}

      :running ->
        {:ok,
         "Eval is still running in background (task_id=#{task_id}, session_id=#{session_id}). " <>
           "Use list_tasks or task_output to check progress, stop_task to cancel."}
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%{task_id: task_id, code: code, topic: topic, session_id: session_id}) do
    server = self()

    if topic, do: broadcast_topic_events(task_id, topic)

    {:ok, io_device} = Froth.Tasks.EvalIO.start_link(task_id)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), io_device)
        result = eval_code(code, session_id)
        io_output = Froth.Tasks.EvalIO.contents(io_device)
        send(server, {:eval_done, result, io_output})
      end)

    Span.execute([:froth, :tasks, :eval_started], nil, %{
      task_id: task_id,
      session_id: session_id,
      code_preview: String.slice(code, 0, 200)
    })

    Froth.Tasks.start(task_id)

    {:ok,
     %{
       task_id: task_id,
       session_id: session_id,
       topic: topic,
       eval_pid: pid,
       eval_ref: ref,
       io_device: io_device,
       result: nil,
       io_output: nil,
       is_error: false,
       done: false,
       waiters: []
     }}
  end

  @impl true
  def handle_call(:task_id, _from, state) do
    {:reply, state.task_id, state}
  end

  def handle_call({:await, _timeout_ms}, _from, %{done: true} = state) do
    {:reply, {:completed, format_result(state), state.is_error}, state}
  end

  def handle_call({:await, timeout_ms}, from, state) do
    timer = Process.send_after(self(), {:await_timeout, from}, timeout_ms)
    {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}
  end

  def handle_call(:stop_eval, _from, %{done: false, eval_pid: pid} = state) when is_pid(pid) do
    Process.exit(pid, :kill)
    {:reply, :ok, state}
  end

  def handle_call(:stop_eval, _from, state) do
    {:reply, {:error, :already_done}, state}
  end

  @impl true
  def handle_info({:eval_done, result, io_output}, state) do
    {is_error, status} =
      case result do
        {:ok, _} -> {false, "completed"}
        {:error, _} -> {true, "failed"}
      end

    Span.execute([:froth, :tasks, :eval_done], nil, %{
      task_id: state.task_id,
      session_id: state.session_id,
      status: status,
      result_preview:
        result |> format_result_parts(io_output, state.session_id) |> String.slice(0, 200)
    })

    result_text = format_result_parts(result, io_output, state.session_id)
    Froth.Tasks.append(state.task_id, "stdout", result_text)

    if status == "completed" do
      Froth.Tasks.complete(state.task_id)
    else
      reason =
        case result do
          {:error, msg} -> msg
          _ -> "unknown error"
        end

      Froth.Tasks.fail(state.task_id, String.slice(reason, 0, 200))
    end

    state = %{state | result: result, io_output: io_output, is_error: is_error, done: true}
    reply_to_waiters(state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{eval_ref: ref, done: false} = state) do
    error_msg = "Eval process crashed: #{inspect(reason)}"

    Span.execute([:froth, :tasks, :eval_crashed], nil, %{
      task_id: state.task_id,
      session_id: state.session_id,
      reason: inspect(reason)
    })

    Froth.Tasks.append(state.task_id, "stderr", error_msg)
    Froth.Tasks.fail(state.task_id, String.slice(error_msg, 0, 200))

    state = %{state | result: {:error, error_msg}, is_error: true, done: true}
    reply_to_waiters(state)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:await_timeout, from}, state) do
    state = %{state | waiters: Enum.reject(state.waiters, fn {f, _} -> f == from end)}
    GenServer.reply(from, :running)
    {:noreply, state}
  end

  def handle_info(:idle_shutdown, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp via(task_id) do
    {:via, Registry, {Froth.Tasks.Registry, task_id}}
  end

  defp eval_code(code, session_id) when is_binary(code) and is_binary(session_id) do
    binding = Froth.Tasks.EvalSessions.binding(session_id)

    try do
      {value, updated_binding} = Code.eval_string(code, binding)
      :ok = Froth.Tasks.EvalSessions.put_binding(session_id, updated_binding)
      {:ok, value}
    rescue
      e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
    catch
      kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
    end
  end

  defp format_result(state) do
    format_result_parts(state.result, state.io_output, state.session_id)
  end

  defp format_result_parts(result, io_output, session_id) do
    session_part = "Session: #{session_id}\n\n"

    io_part =
      case String.trim(io_output || "") do
        "" -> ""
        trimmed -> "IO output:\n#{trimmed}\n\n"
      end

    case result do
      {:ok, value} ->
        inspected = inspect(value, pretty: true, limit: 500, printable_limit: :infinity)
        "#{session_part}#{io_part}#{inspected}"

      {:error, msg} ->
        "#{session_part}#{io_part}#{msg}"
    end
  end

  defp reply_to_waiters(state) do
    formatted = format_result(state)

    for {from, timer} <- state.waiters do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:completed, formatted, state.is_error})
    end

    if state.topic do
      detail = %{
        status: if(state.is_error, do: :error, else: :ok),
        session_id: state.session_id,
        io_output: state.io_output || "",
        result: formatted
      }

      Froth.broadcast(state.topic, {:eval_done_detail, detail})
    end

    Process.send_after(self(), :idle_shutdown, @idle_timeout_ms)
    {:noreply, %{state | waiters: []}}
  end

  defp broadcast_topic_events(task_id, topic) when is_binary(topic) do
    Froth.Tasks.subscribe(task_id)

    spawn(fn ->
      Froth.broadcast(topic, {:tool_started, nil})

      bridge_loop(topic)
    end)
  end

  defp broadcast_topic_events(_, _), do: :ok

  defp bridge_loop(topic) do
    receive do
      {:task_event, _task_id, %Froth.TaskEvent{kind: "stdout", content: content}} ->
        Froth.broadcast(topic, {:io_chunk, content})
        bridge_loop(topic)

      {:task_event, _task_id, %Froth.TaskEvent{kind: "status", content: "completed"}} ->
        :ok

      {:task_event, _task_id, %Froth.TaskEvent{kind: "status", content: "failed: " <> _}} ->
        :ok

      _ ->
        bridge_loop(topic)
    after
      :timer.minutes(30) -> :ok
    end
  end
end
