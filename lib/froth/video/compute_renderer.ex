defmodule Froth.Video.ComputeRenderer do
  @moduledoc false

  alias Froth.Compute
  alias Froth.ObjectStore
  alias Froth.Video.{RenderSupport, WorkerFleet}

  @default_worker_type "browser_render"

  def record(html, opts \\ []) when is_binary(html) and is_list(opts) do
    with {:ok, plan} <- RenderSupport.prepare_recording(html, opts) do
      try do
        with {:ok, job} <- create_job(plan, opts) do
          :ok = maybe_notify_job(job.id, opts)

          case do_record(job.id, plan, opts) do
            {:ok, output_path} ->
              metadata =
                %{"output_path" => output_path}
                |> maybe_put_output_url(plan, opts)

              with {:ok, _job} <- Compute.complete_job(job.id, metadata) do
                {:ok, output_path}
              end

            {:error, reason} = error ->
              _ = Compute.fail_job(job.id, inspect(reason, printable_limit: :infinity))
              error
          end
        end
      after
        RenderSupport.cleanup_recording(plan)
      end
    end
  end

  defp do_record(job_id, plan, opts) do
    with {:ok, spec} <- store_render_spec(plan),
         :ok <- enqueue_batches(job_id, plan, spec, opts),
         :ok <- run_workers(job_id, plan, opts),
         :ok <- hydrate_frames(job_id, plan),
         :ok <- RenderSupport.verify_frames(plan),
         :ok <- RenderSupport.mux_frames(plan, opts) do
      {:ok, plan.output_path}
    end
  end

  defp create_job(plan, opts) do
    label = Keyword.get(opts, :label, "video render #{plan.render_id}")

    Compute.create_job(%{
      type: "video.render",
      label: label,
      metadata: %{
        "render_id" => plan.render_id,
        "output_path" => plan.output_path,
        "frame_count" => plan.frame_count,
        "width" => plan.width,
        "height" => plan.height,
        "fps" => plan.fps
      }
    })
  end

  defp store_render_spec(plan) do
    key = "video/#{plan.render_id}/spec/episode.html"

    case ObjectStore.put_file(key, plan.html_path, content_type: "text/html") do
      {:ok, stored} -> {:ok, stored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_batches(job_id, plan, spec, opts) do
    frames_per_batch = frames_per_batch(opts, plan)

    0..(plan.frame_count - 1)
    |> Enum.chunk_every(frames_per_batch)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {frames, batch_index}, _acc ->
      from_frame = hd(frames)
      to_frame = List.last(frames)

      task_attrs = %{
        stage: "render",
        kind: "frame_batch",
        worker_type: worker_type(opts),
        priority: -batch_index,
        payload: %{
          "render_id" => plan.render_id,
          "spec_key" => spec.key,
          "spec_url" => spec.url,
          "width" => plan.width,
          "height" => plan.height,
          "fps" => plan.fps,
          "from_frame" => from_frame,
          "to_frame" => to_frame,
          "browser_boot_timeout_ms" => plan.browser_boot_timeout_ms
        },
        metadata: %{
          "batch_index" => batch_index,
          "frame_count" => length(frames)
        }
      }

      case Compute.create_task(job_id, task_attrs) do
        {:ok, _task} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_workers(job_id, plan, opts) do
    offers = WorkerFleet.worker_offers(opts)

    job_opts =
      opts
      |> Keyword.put_new(:heartbeat_every_frames, plan.fps)
      |> Keyword.put(:worker_offers, offers)
      |> Keyword.put(
        :compute_workers,
        min(requested_worker_count(opts, plan, offers), plan.frame_count)
      )

    case WorkerFleet.run(job_id, plan.render_id, job_opts) do
      :ok ->
        finalize_job_tasks(job_id)

      {:error, reason} = error ->
        _ = Compute.cancel_job(job_id, %{"reason" => inspect(reason, printable_limit: :infinity)})
        error
    end
  end

  defp hydrate_frames(job_id, plan) do
    job_id
    |> Compute.list_job_artifacts()
    |> Enum.filter(&(&1.kind == "frame_batch_archive"))
    |> Enum.reduce_while(:ok, fn artifact, _acc ->
      with {:ok, temp_dir} <- tmp_dir("video-hydrate"),
           {:ok, archive_path} <- fetch_artifact_archive(artifact, temp_dir),
           :ok <- extract_archive(archive_path, plan.frames_dir) do
        File.rm_rf(temp_dir)
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp finalize_job_tasks(job_id) do
    tasks = Compute.list_job_tasks(job_id)

    case Enum.reject(tasks, &(&1.status == "completed")) do
      [] ->
        :ok

      failed_tasks ->
        {:error,
         {:compute_tasks_incomplete,
          Enum.map(failed_tasks, fn task ->
            %{id: task.id, status: task.status, error: task.error}
          end)}}
    end
  end

  defp maybe_notify_job(job_id, opts) do
    if pid = Keyword.get(opts, :notify_pid) do
      send(pid, {:video_compute_job, job_id})
    end

    :ok
  end

  defp maybe_put_output_url(metadata, plan, opts) do
    if Keyword.get(opts, :store_final_output?, true) do
      key = "video/#{plan.render_id}/final/#{Path.basename(plan.output_path)}"

      case ObjectStore.put_file(key, plan.output_path, content_type: "video/mp4") do
        {:ok, %{url: url}} -> Map.put(metadata, "output_url", url)
        {:error, _reason} -> metadata
      end
    else
      metadata
    end
  end

  defp fetch_artifact_archive(artifact, temp_dir) do
    basename =
      if is_binary(artifact.uri) and artifact.uri != "" do
        Path.basename(artifact.uri)
      else
        "batch.tar.gz"
      end

    destination = Path.join(temp_dir, basename)
    key = get_in(artifact.metadata || %{}, ["key"])

    cond do
      is_binary(key) and key != "" ->
        ObjectStore.fetch(key, destination)

      is_binary(artifact.uri) and artifact.uri != "" ->
        ObjectStore.fetch_url(artifact.uri, destination)

      true ->
        {:error, :missing_artifact_location}
    end
  end

  defp extract_archive(archive_path, destination_dir) do
    case System.cmd("tar", ["-xzf", archive_path, "-C", destination_dir], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:tar_extract_failed, code, output}}
    end
  end

  defp worker_type(opts), do: Keyword.get(opts, :worker_type, @default_worker_type)

  defp frames_per_batch(opts, plan) do
    opts
    |> Keyword.get(:frames_per_batch, default_frames_per_batch(plan))
    |> normalize_positive_integer(default_frames_per_batch(plan))
  end

  defp default_frames_per_batch(plan), do: max(plan.fps * 2, 1)

  defp tmp_dir(prefix) do
    path =
      Path.join(RenderSupport.render_root(), "#{prefix}-#{System.unique_integer([:positive])}")

    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
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

  defp requested_worker_count(opts, plan, offers) do
    opts
    |> Keyword.get(:compute_workers, total_available_worker_slots(offers))
    |> normalize_positive_integer(total_available_worker_slots(offers))
    |> min(plan.frame_count)
    |> max(1)
  end

  defp total_available_worker_slots(offers) do
    offers
    |> Enum.map(&max(&1.slots, 0))
    |> Enum.sum()
    |> max(1)
  end
end
