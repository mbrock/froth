defmodule Froth.Video.ComputeWorker do
  @moduledoc false

  alias Froth.Browser.Chrome
  alias Froth.Compute
  alias Froth.ObjectStore
  alias Froth.Video.RenderSupport

  @default_worker_type "browser_render"

  def run(job_id, render_id, worker_index, opts \\ [])
      when is_binary(job_id) and is_binary(render_id) and is_integer(worker_index) and
             is_list(opts) do
    worker_id = "#{node()}-#{render_id}-#{worker_index}"
    worker_type = worker_type(opts)
    topic = "compute:workers:#{worker_type}"
    lease_seconds = Keyword.get(opts, :lease_seconds, 120) |> normalize_positive_integer(120)
    browser_profile = browser_profile(opts)
    browser_meta = Chrome.profile_metadata(browser_profile)

    heartbeat_every =
      Keyword.get(opts, :heartbeat_every_frames, default_heartbeat_every())
      |> normalize_positive_integer(default_heartbeat_every())

    {:ok, _ref} =
      FrothWeb.ComputePresence.track(self(), topic, worker_id, %{
        slots: 1,
        hostname: hostname(),
        kind: "video_frame_renderer",
        render_id: render_id,
        job_id: job_id,
        platform: platform(),
        browser_profile: Atom.to_string(browser_profile),
        headless: browser_meta.headless?,
        headful: browser_meta.headful?,
        visible: browser_meta.visible?,
        gpu: browser_meta.gpu?,
        webcodecs: browser_meta.webcodecs?,
        codecs: browser_meta.codecs,
        browser_family: browser_meta.browser_family
      })

    do_run(job_id, worker_type, worker_id, lease_seconds, heartbeat_every, browser_profile, opts)
  end

  def local_offer(opts \\ []) when is_list(opts) do
    slots = local_worker_slots(opts)
    browser_profile = browser_profile(opts)
    browser_meta = Chrome.profile_metadata(browser_profile)

    %{
      node: node(),
      hostname: hostname(),
      slots: slots,
      platform: platform(),
      browser_profile: Atom.to_string(browser_profile),
      headless: browser_meta.headless?,
      headful: browser_meta.headful?,
      visible: browser_meta.visible?,
      gpu: browser_meta.gpu?,
      webcodecs: browser_meta.webcodecs?,
      codecs: browser_meta.codecs,
      browser_family: browser_meta.browser_family
    }
  end

  defp do_run(
         job_id,
         worker_type,
         worker_id,
         lease_seconds,
         heartbeat_every,
         browser_profile,
         opts
       ) do
    case compute_call(opts, :request_lease, [
           worker_type,
           worker_id,
           [job_id: job_id, lease_seconds: lease_seconds]
         ]) do
      {:ok, nil} ->
        :ok

      {:ok, task} ->
        case run_leased_batch(task, worker_id, heartbeat_every, browser_profile, opts) do
          :ok ->
            do_run(
              job_id,
              worker_type,
              worker_id,
              lease_seconds,
              heartbeat_every,
              browser_profile,
              opts
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_leased_batch(task, worker_id, heartbeat_every, browser_profile, opts) do
    payload = task.payload || %{}
    from_frame = payload["from_frame"] || 0
    to_frame = payload["to_frame"] || 0
    browser_label = "video batch #{from_frame}-#{to_frame}"

    checkout_timeout_ms =
      Keyword.get(opts, :browser_checkout_timeout_ms, 15_000)
      |> normalize_positive_integer(15_000)

    IO.puts("Worker #{worker_id} leased frames #{from_frame}..#{to_frame}")

    with {:ok, temp_dir} <- tmp_dir("video-batch"),
         {:ok, spec_path} <- download_render_spec(payload, temp_dir),
         {:ok, batch_dir} <- ensure_batch_frames_dir(temp_dir) do
      plan = payload_plan(payload, spec_path, batch_dir)

      result =
        with {:ok, browser_id} <-
               Froth.Browser.checkout(
                 label: browser_label,
                 timeout_ms: checkout_timeout_ms,
                 profile: browser_profile
               ) do
          try do
            with :ok <- RenderSupport.boot_browser(browser_id, plan),
                 :ok <-
                   RenderSupport.render_frame_range(
                     browser_id,
                     plan,
                     from_frame,
                     to_frame,
                     on_frame: fn frame_index, _frame_total ->
                       heartbeat_if_needed(
                         task,
                         worker_id,
                         frame_index,
                         from_frame,
                         heartbeat_every,
                         opts
                       )
                     end
                   ),
                 {:ok, archive_key, archive_url} <-
                   store_batch_archive(payload["render_id"], batch_dir, from_frame, to_frame) do
              {:ok, archive_key, archive_url}
            end
          after
            _ = Froth.Browser.release(browser_id)
          end
        end

      response =
        case result do
          {:ok, archive_key, archive_url} ->
            case compute_call(opts, :complete_task, [
                   task.id,
                   task.lease_token,
                   worker_id,
                   %{
                     metadata: %{"frames_rendered" => to_frame - from_frame + 1},
                     artifacts: [
                       %{
                         kind: "frame_batch_archive",
                         uri: archive_url,
                         metadata: %{
                           "key" => archive_key,
                           "from_frame" => from_frame,
                           "to_frame" => to_frame,
                           "worker_id" => worker_id,
                           "node" => Atom.to_string(node())
                         }
                       }
                     ]
                   }
                 ]) do
              {:ok, _completed_task} -> :ok
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            _ =
              compute_call(opts, :fail_task, [
                task.id,
                task.lease_token,
                worker_id,
                %{reason: inspect(reason, printable_limit: :infinity)}
              ])

            {:error, reason}
        end

      File.rm_rf(temp_dir)
      response
    end
  end

  defp download_render_spec(payload, temp_dir) do
    path = Path.join(temp_dir, "episode.html")

    cond do
      is_binary(payload["spec_key"]) and payload["spec_key"] != "" ->
        ObjectStore.fetch(payload["spec_key"], path)

      is_binary(payload["spec_url"]) and payload["spec_url"] != "" ->
        ObjectStore.fetch_url(payload["spec_url"], path)

      true ->
        {:error, :missing_render_spec}
    end
  end

  defp ensure_batch_frames_dir(temp_dir) do
    frames_dir = Path.join(temp_dir, "frames")

    case File.mkdir_p(frames_dir) do
      :ok -> {:ok, frames_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload_plan(payload, spec_path, batch_dir) do
    %{
      html_path: spec_path,
      frames_dir: batch_dir,
      width: payload["width"],
      height: payload["height"],
      fps: payload["fps"],
      browser_boot_timeout_ms: payload["browser_boot_timeout_ms"] || 45_000
    }
  end

  defp store_batch_archive(render_id, batch_dir, from_frame, to_frame) do
    basename = batch_basename(from_frame, to_frame)
    archive_path = Path.join(batch_dir, "#{basename}.tar.gz")

    files =
      from_frame..to_frame
      |> Enum.map(fn frame_index ->
        RenderSupport.frame_path(batch_dir, frame_index) |> Path.basename()
      end)

    case System.cmd("tar", ["-czf", archive_path, "-C", batch_dir | files],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        key = "video/#{render_id}/batches/#{basename}.tar.gz"

        case ObjectStore.put_file(key, archive_path, content_type: "application/gzip") do
          {:ok, %{url: url}} -> {:ok, key, url}
          {:error, reason} -> {:error, reason}
        end

      {output, code} ->
        {:error, {:tar_failed, code, output}}
    end
  end

  defp heartbeat_if_needed(task, worker_id, frame_index, from_frame, heartbeat_every, opts) do
    if rem(frame_index - from_frame, heartbeat_every) == 0 do
      case compute_call(opts, :heartbeat_lease, [task.id, task.lease_token, worker_id]) do
        {:ok, _task} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp batch_basename(from_frame, to_frame) do
    "#{pad_frame(from_frame)}-#{pad_frame(to_frame)}"
  end

  defp pad_frame(frame_index) do
    frame_index
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp local_worker_slots(opts) do
    opts
    |> Keyword.get(:compute_worker_slots, default_local_worker_slots())
    |> normalize_positive_integer(default_local_worker_slots())
  end

  defp default_local_worker_slots do
    RenderSupport.video_config()
    |> Keyword.get(:compute_worker_count, 2)
    |> normalize_positive_integer(2)
  end

  defp default_heartbeat_every do
    RenderSupport.video_config()
    |> Keyword.get(:fps, 24)
    |> normalize_positive_integer(24)
  end

  defp worker_type(opts), do: Keyword.get(opts, :worker_type, @default_worker_type)

  defp browser_profile(opts) do
    opts
    |> Keyword.get(:browser_profile, browser_profile_config())
    |> Chrome.normalize_profile()
  end

  defp browser_profile_config do
    browser_config = Application.get_env(:froth, Froth.Browser, [])
    video_config = RenderSupport.video_config()

    video_config
    |> Keyword.get(
      :browser_profile,
      Keyword.get(browser_config, :profile, Chrome.default_profile())
    )
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> nil
    end
  end

  defp platform do
    case :os.type() do
      {family, name} -> "#{family}:#{name}"
      other -> inspect(other)
    end
  end

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

  defp compute_call(opts, function_name, args) do
    case Keyword.get(opts, :compute_node, node()) do
      compute_node when compute_node == node() ->
        apply(Compute, function_name, args)

      compute_node ->
        :erpc.call(compute_node, Compute, function_name, args)
    end
  catch
    :exit, reason -> {:error, reason}
  end
end
