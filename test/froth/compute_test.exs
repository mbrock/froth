defmodule Froth.ComputeTest do
  use ExUnit.Case, async: false

  alias Froth.{Compute, Repo}
  alias Froth.Compute.{Job, Task}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "request_lease marks a task running and starts its job" do
    {:ok, job} = Compute.create_job(%{type: "video.render", label: "Episode render"})

    {:ok, task} =
      Compute.create_task(job.id, %{
        kind: "frame_batch",
        worker_type: "browser",
        payload: %{"from" => 0, "to" => 119}
      })

    assert {:ok, leased} = Compute.request_lease("browser", "worker-1", lease_seconds: 45)

    assert leased.id == task.id
    assert leased.status == "running"
    assert leased.worker_id == "worker-1"
    assert leased.lease_token
    assert leased.attempt == 1
    assert %Job{status: "running"} = Compute.get_job!(job.id)
  end

  test "expired running work can be leased to another worker" do
    {:ok, job} = Compute.create_job(%{type: "video.render"})

    {:ok, task} =
      Compute.create_task(job.id, %{
        kind: "frame_batch",
        worker_type: "browser"
      })

    assert {:ok, leased_once} = Compute.request_lease("browser", "worker-1", lease_seconds: 30)

    expired_at = DateTime.add(DateTime.utc_now(), -5, :second)

    leased_once
    |> Task.changeset(%{lease_expires_at: expired_at})
    |> Repo.update!()

    assert {:ok, leased_twice} = Compute.request_lease("browser", "worker-2", lease_seconds: 30)

    assert leased_twice.id == task.id
    assert leased_twice.worker_id == "worker-2"
    assert leased_twice.attempt == 2
    refute leased_twice.lease_token == leased_once.lease_token
  end

  test "request_lease can be scoped to a specific job" do
    {:ok, job_one} = Compute.create_job(%{type: "video.render"})
    {:ok, job_two} = Compute.create_job(%{type: "video.render"})

    {:ok, task_one} =
      Compute.create_task(job_one.id, %{
        kind: "frame_batch",
        worker_type: "browser",
        priority: 10
      })

    {:ok, task_two} =
      Compute.create_task(job_two.id, %{
        kind: "frame_batch",
        worker_type: "browser",
        priority: 1
      })

    assert {:ok, leased} =
             Compute.request_lease("browser", "worker-1", job_id: job_two.id, lease_seconds: 30)

    assert leased.id == task_two.id
    assert %Task{status: "pending"} = Compute.get_task!(task_one.id)
  end

  test "complete_task records artifacts for the finished work" do
    {:ok, job} = Compute.create_job(%{type: "video.render"})

    {:ok, task} =
      Compute.create_task(job.id, %{
        kind: "segment",
        worker_type: "browser"
      })

    assert {:ok, leased} = Compute.request_lease("browser", "worker-1")

    assert {:ok, completed} =
             Compute.complete_task(task.id, leased.lease_token, "worker-1", %{
               "metadata" => %{"frames" => 120},
               "artifacts" => [
                 %{
                   "kind" => "video_segment",
                   "uri" => "s3://froth/video/segment-0000.mp4",
                   "metadata" => %{"from" => 0, "to" => 119}
                 }
               ]
             })

    assert completed.status == "completed"
    assert completed.metadata["frames"] == 120

    [artifact] = Compute.list_job_artifacts(job.id)
    assert artifact.task_id == task.id
    assert artifact.kind == "video_segment"
    assert artifact.uri == "s3://froth/video/segment-0000.mp4"
  end

  test "cancel_job cancels running tasks" do
    {:ok, job} = Compute.create_job(%{type: "video.render"})

    {:ok, task} =
      Compute.create_task(job.id, %{
        kind: "segment",
        worker_type: "browser"
      })

    assert {:ok, _leased} = Compute.request_lease("browser", "worker-1")

    assert {:ok, %Job{} = cancelled_job} =
             Compute.cancel_job(job.id, %{"reason" => "operator stop"})

    assert cancelled_job.status == "cancelled"
    assert cancelled_job.metadata["reason"] == "operator stop"
    assert %Task{status: "cancelled"} = Compute.get_task!(task.id)
  end
end
