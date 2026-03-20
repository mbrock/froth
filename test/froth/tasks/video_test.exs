defmodule Froth.Tasks.VideoTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Froth.Compute
  alias Froth.Compute.{Artifact, Job}
  alias Froth.ObjectStore
  alias Froth.{Repo, Task}
  alias Froth.Podcast.Script

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    root_dir =
      Path.join(System.tmp_dir!(), "froth-object-store-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:froth, ObjectStore, [])

    Application.put_env(:froth, ObjectStore,
      mode: :local,
      root_dir: root_dir,
      public_base: "http://example.test/froth/objects",
      internal_base: "http://example.test/froth/objects",
      write_token: "test-token"
    )

    on_exit(fn ->
      Application.put_env(:froth, ObjectStore, previous)
      File.rm_rf(root_dir)
    end)

    :ok
  end

  test "run_record/2 fails fast when no audio input is available" do
    assert {:error, message} =
             Froth.Tasks.Video.run_record("<html><body>missing audio</body></html>",
               duration_s: 1.0,
               label: "video task test"
             )

    assert message =~ "missing_audio_input"

    task =
      Repo.one!(
        from(t in Task,
          where: t.type == "video",
          order_by: [desc: t.inserted_at],
          limit: 1
        )
      )

    assert task.status == "failed"
    assert task.label == "video task test"
  end

  test "from_podcast/2 fails fast when the batch does not exist" do
    assert {:error, message} =
             Froth.Video.from_podcast("missing-batch",
               label: "missing podcast video"
             )

    assert message =~ "podcast_not_found"

    task =
      Repo.one!(
        from(t in Task,
          where: t.type == "video",
          order_by: [desc: t.inserted_at],
          limit: 1
        )
      )

    assert task.status == "failed"
    assert task.label == "missing podcast video"
  end

  test "run_record/2 renders batched compute work and records artifacts" do
    audio_path = Path.expand("priv/static/audio/nikolai-braff-blend-95-5.mp3")

    scene =
      "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1080 1920'%3E%3Crect width='1080' height='1920' fill='black'/%3E%3C/svg%3E"

    html =
      Froth.Video.compose(
        [
          %{word: "hello", start: 0.0, end: 0.5},
          %{word: "compute", start: 0.5, end: 1.0}
        ],
        [%{src: scene}],
        nil,
        title: "Compute video test",
        duration_s: 1.0
      )

    assert {:ok, message} =
             Froth.Tasks.Video.run_record(html,
               audio_path: audio_path,
               duration_s: 1.0,
               fps: 4,
               compute_workers: 2,
               frames_per_batch: 2,
               label: "batched compute render"
             )

    assert message =~ "Started video task task_id=" or message =~ "Video completed:"

    task =
      Repo.one!(
        from(t in Task,
          where: t.type == "video" and t.label == "batched compute render",
          order_by: [desc: t.inserted_at],
          limit: 1
        )
      )

    if Froth.Tasks.Video.alive?(task.task_id) do
      [{pid, _}] = Registry.lookup(Froth.Tasks.Registry, task.task_id)
      assert {:completed, {:ok, completed_message}} = Froth.Tasks.Video.await(pid, 90_000)
      assert completed_message =~ "Video completed:"
    end

    task = Repo.get!(Task, task.task_id)

    assert task.status == "completed"
    assert is_binary(task.metadata["output_path"])
    assert File.exists?(task.metadata["output_path"])

    job =
      Repo.one!(
        from(j in Job,
          where: j.type == "video.render",
          order_by: [desc: j.inserted_at],
          limit: 1
        )
      )

    assert job.status == "completed"
    assert job.metadata["output_path"] == task.metadata["output_path"]
    assert is_binary(job.metadata["output_url"])
    assert String.contains?(job.metadata["output_url"], "/froth/objects/video/")

    compute_tasks =
      Repo.all(
        from(t in Compute.Task,
          where: t.job_id == ^job.id,
          order_by: [asc: t.inserted_at]
        )
      )

    assert length(compute_tasks) == 2
    assert Enum.all?(compute_tasks, &(&1.status == "completed"))

    artifacts =
      Repo.all(
        from(a in Artifact,
          where: a.job_id == ^job.id,
          order_by: [asc: a.inserted_at]
        )
      )

    assert length(artifacts) == 2
    assert Enum.all?(artifacts, &(&1.kind == "frame_batch_archive"))

    assert Enum.all?(
             artifacts,
             &String.starts_with?(&1.uri, "http://example.test/froth/objects/video/")
           )

    [first_artifact | _] = artifacts
    assert is_binary(first_artifact.metadata["key"])
    assert {:ok, archived_path} = ObjectStore.local_path(first_artifact.metadata["key"])
    assert File.exists?(archived_path)

    File.rm(task.metadata["output_path"])
  end

  test "render_podcast/2 falls back to estimated words when no transcript source is available" do
    batch_id = "video-test-batch"
    audio_path = Path.expand("priv/static/audio/nikolai-braff-blend-95-5.mp3")

    scene =
      "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1080 1920'%3E%3Crect width='1080' height='1920' fill='black'/%3E%3C/svg%3E"

    Repo.insert!(
      Script.changeset(%Script{}, %{
        batch_id: batch_id,
        label: "Task Layer Test",
        chat_id: 12_345,
        script: [
          %{"speaker" => "daniel", "text" => "hello from the task layer"},
          %{"speaker" => "mikael", "text" => "browser as camera"}
        ],
        status: "queued"
      })
    )

    assert {:ok, result} =
             Froth.Video.render_podcast(batch_id,
               audio_path: audio_path,
               duration_s: 1.0,
               fps: 4,
               send_video?: false,
               scene_count: 1,
               scenes: [%{src: scene}]
             )

    assert result.batch_id == batch_id
    assert result.word_count > 0
    assert result.scene_count == 1
    assert File.exists?(result.output_path)
    File.rm(result.output_path)
  end
end
