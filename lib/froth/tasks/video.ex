defmodule Froth.Tasks.Video do
  @moduledoc """
  Background video rendering tasks.

  Wraps `Froth.Video` so long browser renders and podcast-to-video jobs can run
  asynchronously under `Froth.Tasks.Supervisor`, stream progress into task
  events, and be monitored from Charlie.
  """

  use GenServer, restart: :temporary

  alias Froth.Compute
  alias Froth.Telemetry.Span

  @video_await_ms 3_000
  @idle_timeout_ms :timer.minutes(10)

  def start_link(opts) when is_list(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    job = Keyword.fetch!(opts, :job)

    GenServer.start_link(
      __MODULE__,
      %{task_id: task_id, job: job},
      name: via(task_id)
    )
  end

  def await(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    GenServer.call(pid, {:await, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, _ -> :running
  end

  def stop_video(task_id) when is_binary(task_id) do
    GenServer.call(via(task_id), :stop_video)
  catch
    :exit, _ -> {:error, :not_running}
  end

  def alive?(task_id) when is_binary(task_id) do
    case Registry.lookup(Froth.Tasks.Registry, task_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  def run_record(html, opts \\ []) when is_binary(html) and is_list(opts) do
    task_id = Froth.Tasks.generate_id("video")
    telegram = Keyword.get(opts, :telegram)
    expect_minutes = Keyword.get(opts, :expect_minutes)
    label = Keyword.get(opts, :label, "video render")

    {:ok, _task} =
      Froth.Tasks.create(%{
        task_id: task_id,
        type: "video",
        label: label,
        metadata: %{
          mode: "record",
          output_path: opts[:output_path]
        }
      })

    maybe_subscribe_telegram(task_id, telegram, expect_minutes)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Froth.Tasks.Supervisor,
        {__MODULE__, [task_id: task_id, job: {:record, html, scrub_task_opts(opts)}]}
      )

    case await(pid, @video_await_ms) do
      {:completed, {:ok, result_text}} ->
        {:ok, result_text}

      {:completed, {:error, reason_text}} ->
        {:error, reason_text}

      :running ->
        {:ok,
         "Started video task task_id=#{task_id} " <>
           "(still running, use task_output to check progress and subscribe_task to be notified)"}
    end
  end

  def run_podcast(batch_id, opts \\ []) when is_binary(batch_id) and is_list(opts) do
    task_id = Froth.Tasks.generate_id("video")
    telegram = Keyword.get(opts, :telegram)
    expect_minutes = Keyword.get(opts, :expect_minutes, 20)
    label = Keyword.get(opts, :label, "podcast video #{batch_id}")

    {:ok, _task} =
      Froth.Tasks.create(%{
        task_id: task_id,
        type: "video",
        label: label,
        metadata: %{
          mode: "podcast",
          batch_id: batch_id,
          output_path: opts[:output_path]
        }
      })

    maybe_subscribe_telegram(task_id, telegram, expect_minutes)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Froth.Tasks.Supervisor,
        {__MODULE__, [task_id: task_id, job: {:podcast, batch_id, scrub_task_opts(opts)}]}
      )

    case await(pid, @video_await_ms) do
      {:completed, {:ok, result_text}} ->
        {:ok, result_text}

      {:completed, {:error, reason_text}} ->
        {:error, reason_text}

      :running ->
        {:ok,
         "Started podcast video task task_id=#{task_id} for batch #{batch_id} " <>
           "(rendering in background; use task_output to follow progress)"}
    end
  end

  @impl true
  def init(%{task_id: task_id, job: job}) do
    server = self()
    {:ok, io_device} = Froth.Tasks.EvalIO.start_link(task_id)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), io_device)
        result = run_job(job, server)
        io_output = Froth.Tasks.EvalIO.contents(io_device)
        send(server, {:video_done, result, io_output})
      end)

    Span.execute([:froth, :tasks, :video_started], nil, %{task_id: task_id, job: job_label(job)})
    Froth.Tasks.start(task_id)

    {:ok,
     %{
       task_id: task_id,
       job: job,
       job_pid: pid,
       job_ref: ref,
       compute_job_id: nil,
       io_device: io_device,
       result: nil,
       done: false,
       waiters: []
     }}
  end

  @impl true
  def handle_call({:await, _timeout_ms}, _from, %{done: true, result: result} = state) do
    {:reply, {:completed, result}, state}
  end

  def handle_call({:await, timeout_ms}, from, state) do
    timer = Process.send_after(self(), {:await_timeout, from}, timeout_ms)
    {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}
  end

  def handle_call(:stop_video, _from, %{done: false, job_pid: pid} = state) when is_pid(pid) do
    if is_binary(state.compute_job_id) do
      _ = Compute.cancel_job(state.compute_job_id, %{"reason" => "video task stopped"})
    end

    Process.exit(pid, :shutdown)
    {:reply, :ok, state}
  end

  def handle_call(:stop_video, _from, state) do
    {:reply, {:error, :already_done}, state}
  end

  @impl true
  def handle_info({:video_done, result, _io_output}, state) do
    {reply, state} = finish_task(state, result)
    reply_to_waiters(state, reply)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job_ref: ref, done: false} = state) do
    reason_text = "Video task crashed: #{inspect(reason)}"
    Froth.Tasks.append(state.task_id, "stderr", reason_text)
    Froth.Tasks.fail(state.task_id, String.slice(reason_text, 0, 200))

    Span.execute([:froth, :tasks, :video_crashed], nil, %{
      task_id: state.task_id,
      reason: inspect(reason)
    })

    state = %{state | result: {:error, reason_text}, done: true}
    reply_to_waiters(state, state.result)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:await_timeout, from}, state) do
    state = %{state | waiters: Enum.reject(state.waiters, fn {f, _} -> f == from end)}
    GenServer.reply(from, :running)
    {:noreply, state}
  end

  def handle_info({:video_compute_job, job_id}, state) do
    Froth.Tasks.append(state.task_id, "stdout", "Compute job started: #{job_id}\n")
    {:noreply, %{state | compute_job_id: job_id}}
  end

  def handle_info(:idle_shutdown, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp run_job({:record, html, opts}, server) do
    Froth.Video.record_compute(html, Keyword.put(opts, :notify_pid, server))
  end

  defp run_job({:podcast, batch_id, opts}, server) do
    Froth.Video.render_podcast_compute(batch_id, Keyword.put(opts, :notify_pid, server))
  end

  defp run_job(_job, _server), do: {:error, :invalid_video_job}

  defp finish_task(state, {:ok, path}) when is_binary(path) do
    message = "Video completed: #{path}"
    Froth.Tasks.append(state.task_id, "stdout", message <> "\n")
    Froth.Tasks.complete(state.task_id, %{"output_path" => path})
    {{:ok, message}, %{state | result: {:ok, message}, done: true}}
  end

  defp finish_task(state, {:ok, result}) when is_map(result) do
    message = format_result_map(result)
    Froth.Tasks.append(state.task_id, "stdout", message <> "\n")
    Froth.Tasks.complete(state.task_id, stringify_map_keys(result))
    {{:ok, message}, %{state | result: {:ok, message}, done: true}}
  end

  defp finish_task(state, {:ok, other}) do
    message = "Video completed: #{inspect(other, printable_limit: :infinity)}"
    Froth.Tasks.append(state.task_id, "stdout", message <> "\n")
    Froth.Tasks.complete(state.task_id)
    {{:ok, message}, %{state | result: {:ok, message}, done: true}}
  end

  defp finish_task(state, {:error, reason}) do
    reason_text = format_reason(reason)
    Froth.Tasks.append(state.task_id, "stderr", reason_text <> "\n")
    Froth.Tasks.fail(state.task_id, String.slice(reason_text, 0, 200))

    {{:error, "Video task #{state.task_id} failed: #{reason_text}"},
     %{state | result: {:error, "Video task #{state.task_id} failed: #{reason_text}"}, done: true}}
  end

  defp reply_to_waiters(state, result) do
    for {from, timer} <- state.waiters do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:completed, result})
    end

    Process.send_after(self(), :idle_shutdown, @idle_timeout_ms)
    {:noreply, %{state | waiters: []}}
  end

  defp maybe_subscribe_telegram(_task_id, nil, _expect_minutes), do: :ok

  defp maybe_subscribe_telegram(task_id, telegram, expect_minutes) when is_map(telegram) do
    chat_id = telegram[:chat_id] || telegram["chat_id"]

    if is_integer(chat_id) do
      Froth.Tasks.subscribe_telegram(
        task_id,
        telegram[:bot_id] || telegram["bot_id"] || "charlie",
        chat_id,
        expect_minutes
      )
    else
      :ok
    end
  end

  defp scrub_task_opts(opts) do
    Keyword.drop(opts, [:telegram, :expect_minutes, :label])
  end

  defp format_result_map(result) do
    path = result[:output_path] || result["output_path"]
    batch_id = result[:batch_id] || result["batch_id"]

    cond do
      is_binary(batch_id) and is_binary(path) ->
        "Podcast video #{batch_id} completed: #{path}"

      is_binary(path) ->
        "Video completed: #{path}"

      true ->
        inspect(result, printable_limit: :infinity)
    end
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, printable_limit: :infinity)

  defp job_label({:record, _html, _opts}), do: "record"
  defp job_label({:podcast, batch_id, _opts}), do: "podcast:#{batch_id}"
  defp job_label(_job), do: "unknown"

  defp via(task_id) do
    {:via, Registry, {Froth.Tasks.Registry, task_id}}
  end
end
