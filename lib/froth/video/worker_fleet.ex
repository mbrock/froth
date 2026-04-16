defmodule Froth.Video.WorkerFleet do
  @moduledoc false

  alias Froth.Browser.Chrome
  alias Froth.Video.ComputeWorker

  @offer_timeout_ms 5_000

  def run(job_id, render_id, opts \\ [])
      when is_binary(job_id) and is_binary(render_id) and is_list(opts) do
    offers =
      opts
      |> worker_offers()
      |> Enum.reject(&(&1.slots <= 0))

    requested_workers = requested_worker_count(opts, offers)
    worker_specs = build_worker_specs(offers, requested_workers)

    if worker_specs == [] do
      {:error, :no_compute_workers_available}
    else
      IO.puts(
        "Compute render job #{job_id} running on " <>
          format_worker_specs(worker_specs)
      )

      worker_specs
      |> Enum.map(&start_worker(&1, job_id, render_id, opts))
      |> await_workers()
    end
  end

  def worker_offers(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :worker_offers) do
      offers when is_list(offers) ->
        offers
        |> Enum.uniq_by(& &1.node)
        |> filter_requested_capabilities(opts)
        |> Enum.sort_by(&sort_key/1)

      _ ->
        timeout_ms =
          opts
          |> Keyword.get(:fleet_offer_timeout_ms, @offer_timeout_ms)
          |> normalize_positive_integer(@offer_timeout_ms)

        connected_nodes =
          case Keyword.get(opts, :connected_nodes) do
            nil -> connected_nodes()
            nodes when is_list(nodes) -> nodes
          end

        local_offer = ComputeWorker.local_offer(opts)

        remote_offers =
          connected_nodes
          |> Enum.reject(&(&1 == node()))
          |> Enum.reduce([], fn remote_node, offers ->
            case fetch_remote_offer(remote_node, opts, timeout_ms) do
              nil -> offers
              offer -> [offer | offers]
            end
          end)

        [local_offer | remote_offers]
        |> Enum.uniq_by(& &1.node)
        |> filter_requested_capabilities(opts)
        |> Enum.sort_by(&sort_key/1)
    end
  end

  def build_worker_specs(offers, requested_workers)
      when is_list(offers) and is_integer(requested_workers) do
    offers
    |> slot_sequence()
    |> Enum.take(max(requested_workers, 0))
    |> Enum.with_index(1)
    |> Enum.map(fn {offer, worker_index} ->
      %{
        node: offer.node,
        worker_index: worker_index,
        hostname: offer.hostname,
        browser_profile: offer.browser_profile,
        visible: offer.visible,
        headful: offer.headful,
        gpu: offer.gpu
      }
    end)
  end

  defp requested_worker_count(opts, offers) do
    available_slots =
      offers
      |> Enum.map(&max(&1.slots, 0))
      |> Enum.sum()

    opts
    |> Keyword.get(:compute_workers, available_slots)
    |> normalize_positive_integer(available_slots)
    |> min(max(available_slots, 1))
  end

  defp slot_sequence(offers) do
    max_slots =
      offers
      |> Enum.map(&max(&1.slots, 0))
      |> Enum.max(fn -> 0 end)

    if max_slots <= 0 do
      []
    else
      for slot_round <- 1..max_slots,
          offer <- offers,
          offer.slots >= slot_round do
        offer
      end
    end
  end

  defp start_worker(spec, job_id, render_id, opts) do
    start_fun = Keyword.get(opts, :start_worker_fun, &default_start_worker/4)
    start_fun.(spec, job_id, render_id, opts)
  end

  defp await_workers(tasks) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      task
      |> Task.yield(:infinity)
      |> Kernel.||(Task.shutdown(task, :brutal_kill))
      |> case do
        {:ok, :ok} ->
          {:cont, :ok}

        {:ok, {:error, reason}} ->
          shutdown_workers(tasks)
          {:halt, {:error, reason}}

        {:exit, reason} ->
          shutdown_workers(tasks)
          {:halt, {:error, reason}}

        nil ->
          shutdown_workers(tasks)
          {:halt, {:error, :worker_timeout}}
      end
    end)
  end

  defp shutdown_workers(tasks) do
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)
  end

  defp default_start_worker(spec, job_id, render_id, opts) do
    task_supervisor = task_supervisor(spec.node)
    worker_opts = Keyword.put_new(opts, :compute_node, node())

    Task.Supervisor.async_nolink(task_supervisor, fn ->
      ComputeWorker.run(job_id, render_id, spec.worker_index, worker_opts)
    end)
  end

  defp fetch_remote_offer(remote_node, opts, timeout_ms) do
    remote_offer_opts = Keyword.delete(opts, :browser_profile)
    :erpc.call(remote_node, ComputeWorker, :local_offer, [remote_offer_opts], timeout_ms)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp connected_nodes do
    if Node.alive?(), do: Node.list(), else: []
  end

  defp task_supervisor(remote_node) when remote_node == node(), do: Froth.TaskSupervisor
  defp task_supervisor(remote_node), do: {Froth.TaskSupervisor, remote_node}

  defp format_worker_specs(worker_specs) do
    worker_specs
    |> Enum.group_by(& &1.hostname)
    |> Enum.map(fn {hostname, specs} ->
      profile =
        specs
        |> List.first()
        |> Map.get(:browser_profile)

      "#{hostname || "unknown"} x#{length(specs)} (#{profile})"
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp filter_requested_capabilities(offers, opts) do
    requested_meta =
      opts
      |> Keyword.get(:browser_profile)
      |> requested_profile_metadata()

    Enum.filter(offers, &offer_supports_profile?(&1, requested_meta))
  end

  defp requested_profile_metadata(nil), do: nil
  defp requested_profile_metadata(profile), do: Chrome.profile_metadata(profile)

  defp offer_supports_profile?(_offer, nil), do: true

  defp offer_supports_profile?(offer, requested_meta) do
    supports_flag?(offer, :headless, requested_meta.headless?) and
      supports_flag?(offer, :headful, requested_meta.headful?) and
      supports_flag?(offer, :gpu, requested_meta.gpu?)
  end

  defp supports_flag?(_offer, _flag, false), do: true
  defp supports_flag?(offer, flag, true), do: Map.get(offer, flag) == true

  defp sort_key(offer) do
    {
      offer.visible != true,
      offer.headful != true,
      offer.gpu != true,
      -(offer.slots || 0),
      offer.hostname || "",
      Atom.to_string(offer.node)
    }
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
end
