defmodule FrothWeb.ComputeWorkerChannelTest do
  use FrothWeb.ChannelCase, async: false

  alias Froth.Compute
  alias FrothWeb.{ComputeWorkerChannel, UserSocket}

  test "workers join, appear in presence, and can lease work" do
    {:ok, job} = Compute.create_job(%{type: "video.render"})

    {:ok, task} =
      Compute.create_task(job.id, %{
        kind: "frame_batch",
        worker_type: "browser",
        payload: %{"batch" => 1}
      })

    {:ok, reply, socket} =
      socket(UserSocket, "test-user", %{})
      |> subscribe_and_join(ComputeWorkerChannel, "compute:workers:browser", %{
        "worker_id" => "browser-1",
        "slots" => 2,
        "hostname" => "igloo"
      })

    assert reply == %{worker_id: "browser-1"}

    _ = :sys.get_state(socket.channel_pid)

    assert [
             %{
               worker_id: "browser-1",
               hostname: "igloo",
               slots: 2
             }
           ] = Compute.list_workers("browser")

    ref = push(socket, "request_lease", %{"lease_seconds" => 60})

    assert_reply ref, :ok, %{lease: lease}
    assert lease.id == task.id
    assert lease.payload == %{"batch" => 1}
    assert is_binary(lease.lease_token)
  end

  test "workers can complete leased work through the channel" do
    {:ok, job} = Compute.create_job(%{type: "video.render"})

    {:ok, task} =
      Compute.create_task(job.id, %{
        kind: "segment",
        worker_type: "browser"
      })

    {:ok, _reply, socket} =
      socket(UserSocket, "test-user", %{})
      |> subscribe_and_join(ComputeWorkerChannel, "compute:workers:browser", %{
        "worker_id" => "browser-2"
      })

    ref = push(socket, "request_lease", %{})
    assert_reply ref, :ok, %{lease: lease}

    complete_ref =
      push(socket, "complete", %{
        "task_id" => task.id,
        "lease_token" => lease.lease_token,
        "artifacts" => [
          %{"kind" => "video_segment", "uri" => "file:///tmp/segment.mp4"}
        ]
      })

    task_id = task.id
    assert_reply complete_ref, :ok, %{task_id: ^task_id, status: "completed"}
    assert [%{uri: "file:///tmp/segment.mp4"}] = Compute.list_job_artifacts(job.id)
  end

  test "workers can request a lease for a specific job" do
    {:ok, job_one} = Compute.create_job(%{type: "video.render"})
    {:ok, job_two} = Compute.create_job(%{type: "video.render"})

    {:ok, task_one} =
      Compute.create_task(job_one.id, %{
        kind: "frame_batch",
        worker_type: "browser",
        priority: 20
      })

    {:ok, task_two} =
      Compute.create_task(job_two.id, %{
        kind: "frame_batch",
        worker_type: "browser",
        priority: 1
      })

    {:ok, _reply, socket} =
      socket(UserSocket, "test-user", %{})
      |> subscribe_and_join(ComputeWorkerChannel, "compute:workers:browser", %{
        "worker_id" => "browser-3"
      })

    ref = push(socket, "request_lease", %{"job_id" => job_two.id})
    assert_reply ref, :ok, %{lease: lease}

    assert lease.id == task_two.id
    assert %Compute.Task{status: "pending"} = Compute.get_task!(task_one.id)
  end
end
