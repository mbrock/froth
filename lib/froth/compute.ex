defmodule Froth.Compute do
  @moduledoc """
  Durable job and lease management for distributed compute workers.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Froth.Compute.{Artifact, Job, Task}
  alias Froth.Repo

  @default_lease_seconds 30

  def create_job(attrs) when is_map(attrs) do
    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert()
  end

  def get_job(id) when is_binary(id), do: Repo.get(Job, id)
  def get_job!(id) when is_binary(id), do: Repo.get!(Job, id)

  def complete_job(job_id, metadata_updates \\ %{})
      when is_binary(job_id) and is_map(metadata_updates) do
    now = DateTime.utc_now()

    case Repo.get(Job, job_id) do
      nil ->
        {:error, :job_not_found}

      job ->
        job
        |> Job.changeset(%{
          status: "completed",
          metadata: Map.merge(job.metadata || %{}, metadata_updates),
          finished_at: now,
          error: nil
        })
        |> Repo.update()
    end
  end

  def fail_job(job_id, reason, metadata_updates \\ %{})
      when is_binary(job_id) and is_binary(reason) and is_map(metadata_updates) do
    now = DateTime.utc_now()

    case Repo.get(Job, job_id) do
      nil ->
        {:error, :job_not_found}

      job ->
        job
        |> Job.changeset(%{
          status: "failed",
          metadata: Map.merge(job.metadata || %{}, metadata_updates),
          finished_at: now,
          error: reason
        })
        |> Repo.update()
    end
  end

  def cancel_job(job_id, metadata_updates \\ %{})
      when is_binary(job_id) and is_map(metadata_updates) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case Repo.get(Job, job_id) do
        nil ->
          Repo.rollback(:job_not_found)

        job ->
          cancelled_job =
            job
            |> Job.changeset(%{
              status: "cancelled",
              metadata: Map.merge(job.metadata || %{}, metadata_updates),
              cancelled_at: now,
              finished_at: now
            })
            |> Repo.update!()

          _ =
            from(t in Task,
              where: t.job_id == ^job_id and t.status in ["pending", "running"]
            )
            |> Repo.update_all(
              set: [
                status: "cancelled",
                finished_at: now,
                error: "job cancelled",
                lease_token: nil,
                worker_id: nil,
                lease_expires_at: nil
              ]
            )

          cancelled_job
      end
    end)
    |> normalize_transaction_result()
  end

  def create_task(%Job{id: job_id}, attrs), do: create_task(job_id, attrs)

  def create_task(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    attrs = Map.put_new(attrs, :job_id, job_id)

    case %Task{}
         |> Task.changeset(attrs)
         |> Repo.insert() do
      {:ok, task} ->
        notify_work_available(task.worker_type)
        {:ok, task}

      error ->
        error
    end
  end

  def get_task(id) when is_binary(id), do: Repo.get(Task, id)
  def get_task!(id) when is_binary(id), do: Repo.get!(Task, id)

  def list_job_tasks(job_id) when is_binary(job_id) do
    from(t in Task, where: t.job_id == ^job_id, order_by: [desc: t.priority, asc: t.inserted_at])
    |> Repo.all()
  end

  def list_job_artifacts(job_id) when is_binary(job_id) do
    from(a in Artifact, where: a.job_id == ^job_id, order_by: [asc: a.inserted_at])
    |> Repo.all()
  end

  def request_lease(worker_type, worker_id, opts \\ [])
      when is_binary(worker_type) and is_binary(worker_id) do
    job_id = Keyword.get(opts, :job_id)
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, lease_seconds, :second)

    Repo.transaction(fn ->
      case Repo.one(leaseable_task_query(worker_type, now, job_id)) do
        nil ->
          nil

        task ->
          leased_task =
            task
            |> Task.changeset(%{
              status: "running",
              worker_id: worker_id,
              lease_token: Froth.Tasks.generate_id("lease"),
              lease_expires_at: expires_at,
              last_heartbeat_at: now,
              started_at: task.started_at || now,
              finished_at: nil,
              error: nil,
              attempt: task.attempt + 1
            })
            |> Repo.update!()

          mark_job_running(leased_task.job_id, now)
          leased_task
      end
    end)
  end

  def heartbeat_lease(task_id, lease_token, worker_id, opts \\ [])
      when is_binary(task_id) and is_binary(lease_token) and is_binary(worker_id) do
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, lease_seconds, :second)

    with {:ok, task} <- fetch_active_lease(task_id, lease_token, worker_id, now) do
      task
      |> Task.changeset(%{
        lease_expires_at: expires_at,
        last_heartbeat_at: now
      })
      |> Repo.update()
    end
  end

  def release_task(task_id, lease_token, worker_id)
      when is_binary(task_id) and is_binary(lease_token) and is_binary(worker_id) do
    with {:ok, task} <- fetch_owned_task(task_id, lease_token, worker_id) do
      case task
           |> Task.changeset(%{
             status: "pending",
             lease_token: nil,
             worker_id: nil,
             lease_expires_at: nil,
             last_heartbeat_at: nil,
             error: nil
           })
           |> Repo.update() do
        {:ok, released_task} ->
          notify_work_available(released_task.worker_type)
          {:ok, released_task}

        error ->
          error
      end
    end
  end

  def cancel_task(task_id, metadata_updates \\ %{})
      when is_binary(task_id) and is_map(metadata_updates) do
    now = DateTime.utc_now()

    case Repo.get(Task, task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        task
        |> Task.changeset(%{
          status: "cancelled",
          metadata: Map.merge(task.metadata || %{}, metadata_updates),
          finished_at: now,
          lease_token: nil,
          worker_id: nil,
          lease_expires_at: nil,
          error: "task cancelled"
        })
        |> Repo.update()
    end
  end

  def complete_task(task_id, lease_token, worker_id, attrs \\ %{})
      when is_binary(task_id) and is_binary(lease_token) and is_binary(worker_id) and
             is_map(attrs) do
    metadata_updates = Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    artifacts = Map.get(attrs, :artifacts, Map.get(attrs, "artifacts", []))
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      with {:ok, task} <- fetch_active_lease(task_id, lease_token, worker_id, now),
           {:ok, completed_task} <- complete_task_record(task, metadata_updates, now),
           {:ok, _artifacts} <- insert_artifacts(completed_task, artifacts) do
        completed_task
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  def fail_task(task_id, lease_token, worker_id, attrs \\ %{})
      when is_binary(task_id) and is_binary(lease_token) and is_binary(worker_id) and
             is_map(attrs) do
    metadata_updates = Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    reason = Map.get(attrs, :reason, Map.get(attrs, "reason", "task failed"))
    now = DateTime.utc_now()

    with {:ok, task} <- fetch_active_lease(task_id, lease_token, worker_id, now) do
      task
      |> Task.changeset(%{
        status: "failed",
        metadata: Map.merge(task.metadata || %{}, metadata_updates),
        finished_at: now,
        error: reason,
        lease_token: nil,
        worker_id: nil,
        lease_expires_at: nil
      })
      |> Repo.update()
    end
  end

  def record_artifact(attrs) when is_map(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert()
  end

  def list_workers(worker_type) when is_binary(worker_type) do
    worker_type
    |> worker_topic()
    |> FrothWeb.ComputePresence.list()
    |> Enum.flat_map(fn {worker_id, %{metas: metas}} ->
      Enum.map(metas, &Map.put(&1, :worker_id, worker_id))
    end)
    |> Enum.sort_by(&{Map.get(&1, :hostname), Map.get(&1, :worker_id)})
  end

  defp complete_task_record(task, metadata_updates, now) do
    task
    |> Task.changeset(%{
      status: "completed",
      metadata: Map.merge(task.metadata || %{}, metadata_updates),
      finished_at: now,
      error: nil,
      lease_token: nil,
      worker_id: nil,
      lease_expires_at: nil
    })
    |> Repo.update()
  end

  defp insert_artifacts(task, artifacts) when is_list(artifacts) do
    multi =
      Enum.reduce(artifacts, Multi.new(), fn artifact_attrs, multi ->
        attrs =
          artifact_attrs
          |> stringify_keys_to_atoms()
          |> Map.put_new(:job_id, task.job_id)
          |> Map.put_new(:task_id, task.id)

        key = {:artifact, attrs.kind, attrs.uri}

        Multi.insert(multi, key, Artifact.changeset(%Artifact{}, attrs))
      end)

    case Repo.transaction(multi) do
      {:ok, result} ->
        inserted =
          result
          |> Map.values()
          |> Enum.filter(&match?(%Artifact{}, &1))

        {:ok, inserted}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp fetch_owned_task(task_id, lease_token, worker_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :task_not_found}

      %Task{lease_token: ^lease_token, worker_id: ^worker_id, status: "running"} = task ->
        {:ok, task}

      _task ->
        {:error, :lease_not_found}
    end
  end

  defp fetch_active_lease(task_id, lease_token, worker_id, now) do
    with {:ok, task} <- fetch_owned_task(task_id, lease_token, worker_id) do
      case task.lease_expires_at do
        nil ->
          {:error, :lease_not_found}

        lease_expires_at ->
          case DateTime.compare(lease_expires_at, now) do
            :lt -> {:error, :lease_expired}
            _ -> {:ok, task}
          end
      end
    end
  end

  defp leaseable_task_query(worker_type, now, job_id) do
    base_query =
      from(t in Task,
        where:
          t.worker_type == ^worker_type and
            t.attempt < t.max_attempts and
            (t.status == "pending" or
               (t.status == "running" and
                  not is_nil(t.lease_expires_at) and
                  t.lease_expires_at < ^now))
      )

    base_query =
      if is_binary(job_id) and job_id != "" do
        from(t in base_query, where: t.job_id == ^job_id)
      else
        base_query
      end

    from(t in base_query,
      order_by: [desc: t.priority, asc: t.inserted_at],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  defp mark_job_running(job_id, now) do
    from(j in Job, where: j.id == ^job_id and j.status == "pending")
    |> Repo.update_all(set: [status: "running", started_at: now])
  end

  defp notify_work_available(worker_type) do
    FrothWeb.Endpoint.broadcast(worker_topic(worker_type), "work_available", %{
      worker_type: worker_type
    })
  end

  defp worker_topic(worker_type), do: "compute:workers:#{worker_type}"

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp stringify_keys_to_atoms(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case key do
          "job_id" -> Map.put(acc, :job_id, value)
          "task_id" -> Map.put(acc, :task_id, value)
          "kind" -> Map.put(acc, :kind, value)
          "uri" -> Map.put(acc, :uri, value)
          "checksum" -> Map.put(acc, :checksum, value)
          "size" -> Map.put(acc, :size, value)
          "metadata" -> Map.put(acc, :metadata, value)
          _ -> acc
        end
    end)
  end
end
