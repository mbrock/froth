defmodule Froth.Tasks.VideoTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Froth.Compute
  alias Froth.Compute.{Artifact, Job}
  alias Froth.ObjectStore
  alias Froth.{Repo, Task}
  alias Froth.Podcast.Script
  alias Froth.Video.RenderSupport

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
               worker_offers: fake_worker_offers(),
               start_worker_fun: &fake_batch_worker/4,
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
               record_fun: &fake_record/2,
               scene_count: 1,
               scenes: [%{src: scene}]
             )

    assert result.batch_id == batch_id
    assert result.word_count > 0
    assert result.scene_count == 1
    assert File.exists?(result.output_path)
    File.rm(result.output_path)
  end

  defp fake_worker_offers do
    [
      %{
        node: node(),
        hostname: "test-host",
        slots: 2,
        browser_profile: "test",
        visible: false,
        headful: false,
        gpu: false
      }
    ]
  end

  defp fake_batch_worker(spec, job_id, render_id, opts) do
    Elixir.Task.async(fn ->
      worker_id = "test-#{render_id}-#{spec.worker_index}"
      run_fake_batches(job_id, render_id, worker_id, opts)
    end)
  end

  defp run_fake_batches(job_id, render_id, worker_id, opts) do
    worker_type = Keyword.get(opts, :worker_type, "browser_render")
    lease_seconds = Keyword.get(opts, :lease_seconds, 120)

    case Compute.request_lease(worker_type, worker_id,
           job_id: job_id,
           lease_seconds: lease_seconds
         ) do
      {:ok, nil} ->
        :ok

      {:ok, task} ->
        with {:ok, archive_key, archive_url} <-
               store_fake_batch_archive(render_id, task.payload || %{}),
             {:ok, _task} <-
               Compute.complete_task(task.id, task.lease_token, worker_id, %{
                 metadata: %{"frames_rendered" => batch_frame_count(task.payload || %{})},
                 artifacts: [
                   %{
                     kind: "frame_batch_archive",
                     uri: archive_url,
                     metadata: %{
                       "key" => archive_key,
                       "from_frame" => task.payload["from_frame"],
                       "to_frame" => task.payload["to_frame"],
                       "worker_id" => worker_id,
                       "node" => Atom.to_string(node())
                     }
                   }
                 ]
               }) do
          run_fake_batches(job_id, render_id, worker_id, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_fake_batch_archive(render_id, payload) do
    from_frame = payload["from_frame"] || 0
    to_frame = payload["to_frame"] || from_frame
    basename = frame_batch_basename(from_frame, to_frame)

    with {:ok, temp_dir} <- temp_dir("video-test-batch"),
         :ok <- write_fake_frames(temp_dir, from_frame, to_frame),
         {:ok, archive_path} <- create_archive(temp_dir, basename, from_frame, to_frame) do
      key = "video/#{render_id}/batches/#{basename}.tar.gz"

      try do
        case ObjectStore.put_file(key, archive_path, content_type: "application/gzip") do
          {:ok, %{url: url}} -> {:ok, key, url}
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  defp write_fake_frames(frames_dir, from_frame, to_frame) do
    source_png = Path.expand("priv/static/icons/icon-192.png")

    Enum.reduce_while(from_frame..to_frame, :ok, fn frame_index, :ok ->
      destination = RenderSupport.frame_path(frames_dir, frame_index)

      case File.cp(source_png, destination) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_archive(frames_dir, basename, from_frame, to_frame) do
    archive_path = Path.join(frames_dir, "#{basename}.tar.gz")

    files =
      Enum.map(from_frame..to_frame, fn frame_index ->
        RenderSupport.frame_path(frames_dir, frame_index) |> Path.basename()
      end)

    case System.cmd("tar", ["-czf", archive_path, "-C", frames_dir | files],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, archive_path}
      {output, code} -> {:error, {:tar_failed, code, output}}
    end
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")

    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp frame_batch_basename(from_frame, to_frame) do
    "#{pad_frame(from_frame)}-#{pad_frame(to_frame)}"
  end

  defp batch_frame_count(payload) do
    from_frame = payload["from_frame"] || 0
    to_frame = payload["to_frame"] || from_frame
    to_frame - from_frame + 1
  end

  defp pad_frame(frame_index) do
    frame_index
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp fake_record(_html, opts) do
    output_path = Keyword.fetch!(opts, :output_path)

    with :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- File.write(output_path, "fake mp4") do
      {:ok, output_path}
    end
  end
end
