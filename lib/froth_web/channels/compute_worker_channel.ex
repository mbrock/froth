defmodule FrothWeb.ComputeWorkerChannel do
  use FrothWeb, :channel

  alias Froth.Compute
  alias FrothWeb.ComputePresence

  @impl true
  def join("compute:workers:" <> worker_type, params, socket) do
    worker_id = Map.get(params, "worker_id") || Froth.Tasks.generate_id("worker")

    socket =
      socket
      |> assign(:worker_id, worker_id)
      |> assign(:worker_type, worker_type)
      |> assign(:worker_meta, worker_meta(params))

    send(self(), :track_presence)
    {:ok, %{worker_id: worker_id}, socket}
  end

  @impl true
  def handle_info(:track_presence, socket) do
    {:ok, _ref} =
      ComputePresence.track(socket, socket.assigns.worker_id, socket.assigns.worker_meta)

    {:noreply, socket}
  end

  @impl true
  def handle_in("request_lease", params, socket) do
    lease_seconds = lease_seconds(params)

    request_opts =
      [
        lease_seconds: lease_seconds,
        job_id: job_id(params)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Compute.request_lease(
           socket.assigns.worker_type,
           socket.assigns.worker_id,
           request_opts
         ) do
      {:ok, nil} ->
        {:reply, {:ok, %{lease: nil}}, socket}

      {:ok, task} ->
        {:reply, {:ok, %{lease: serialize_task(task)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("heartbeat", params, socket) do
    lease_seconds = lease_seconds(params)

    with {:ok, task_id} <- required_param(params, "task_id"),
         {:ok, lease_token} <- required_param(params, "lease_token"),
         {:ok, task} <-
           Compute.heartbeat_lease(task_id, lease_token, socket.assigns.worker_id,
             lease_seconds: lease_seconds
           ) do
      {:reply, {:ok, %{lease: serialize_task(task)}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("release", params, socket) do
    with {:ok, task_id} <- required_param(params, "task_id"),
         {:ok, lease_token} <- required_param(params, "lease_token"),
         {:ok, task} <- Compute.release_task(task_id, lease_token, socket.assigns.worker_id) do
      {:reply, {:ok, %{task_id: task.id, status: task.status}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("complete", params, socket) do
    with {:ok, task_id} <- required_param(params, "task_id"),
         {:ok, lease_token} <- required_param(params, "lease_token"),
         {:ok, task} <-
           Compute.complete_task(task_id, lease_token, socket.assigns.worker_id, params) do
      {:reply, {:ok, %{task_id: task.id, status: task.status}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("fail", params, socket) do
    with {:ok, task_id} <- required_param(params, "task_id"),
         {:ok, lease_token} <- required_param(params, "lease_token"),
         {:ok, task} <- Compute.fail_task(task_id, lease_token, socket.assigns.worker_id, params) do
      {:reply, {:ok, %{task_id: task.id, status: task.status, error: task.error}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{error: Atom.to_string(reason)}}, socket}
    end
  end

  defp worker_meta(params) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      slots: slots(params),
      capabilities: Map.get(params, "capabilities", %{}),
      hostname: Map.get(params, "hostname"),
      version: Map.get(params, "version"),
      joined_at: now
    }
  end

  defp slots(params) do
    params
    |> Map.get("slots", 1)
    |> normalize_positive_integer(1)
  end

  defp lease_seconds(params) do
    params
    |> Map.get("lease_seconds", 30)
    |> normalize_positive_integer(30)
  end

  defp required_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :bad_request}
    end
  end

  defp job_id(params) do
    case Map.get(params, "job_id") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp normalize_positive_integer(value, default) when is_integer(value) do
    if value > 0, do: value, else: default
  end

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp serialize_task(task) do
    %{
      id: task.id,
      job_id: task.job_id,
      stage: task.stage,
      kind: task.kind,
      worker_type: task.worker_type,
      status: task.status,
      priority: task.priority,
      payload: task.payload,
      metadata: task.metadata,
      attempt: task.attempt,
      max_attempts: task.max_attempts,
      lease_token: task.lease_token,
      lease_expires_at: task.lease_expires_at
    }
  end
end
