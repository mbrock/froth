defmodule FrothWeb.JobsLive do
  use FrothWeb, :live_view

  import Ecto.Query

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     socket
     |> assign(:filter_state, "all")
     |> assign(:filter_queue, "all")
     |> assign(:page, 0)
     |> assign(:page_size, 50)
     |> load_jobs()
     |> load_stats()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, socket |> load_jobs() |> load_stats()}
  end

  @impl true
  def handle_event("filter-state", %{"state" => state}, socket) do
    {:noreply, socket |> assign(:filter_state, state) |> assign(:page, 0) |> load_jobs()}
  end

  @impl true
  def handle_event("filter-queue", %{"queue" => queue}, socket) do
    {:noreply, socket |> assign(:filter_queue, queue) |> assign(:page, 0) |> load_jobs()}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_jobs()}
  end

  @impl true
  def handle_event("prev-page", _, socket) do
    page = max(0, socket.assigns.page - 1)
    {:noreply, socket |> assign(:page, page) |> load_jobs()}
  end

  @impl true
  def handle_event("retry-job", %{"id" => id_str}, socket) do
    {id, ""} = Integer.parse(id_str)
    Oban.retry_job(id)
    {:noreply, socket |> load_jobs()}
  end

  @impl true
  def handle_event("cancel-job", %{"id" => id_str}, socket) do
    {id, ""} = Integer.parse(id_str)
    Oban.cancel_job(id)
    {:noreply, socket |> load_jobs()}
  end

  defp load_jobs(socket) do
    state = socket.assigns.filter_state
    queue = socket.assigns.filter_queue
    page = socket.assigns.page
    page_size = socket.assigns.page_size

    q =
      from(j in Oban.Job, order_by: [desc: j.id], limit: ^page_size, offset: ^(page * page_size))

    q = if state != "all", do: where(q, [j], j.state == ^state), else: q
    q = if queue != "all", do: where(q, [j], j.queue == ^queue), else: q

    jobs = Froth.Repo.all(q)
    assign(socket, :jobs, jobs)
  end

  defp load_stats(socket) do
    stats =
      Froth.Repo.all(
        from(j in Oban.Job,
          group_by: [j.state, j.queue],
          select: %{state: j.state, queue: j.queue, count: count(j.id)}
        )
      )

    queues =
      stats
      |> Enum.map(& &1.queue)
      |> Enum.uniq()
      |> Enum.sort()

    state_counts =
      stats
      |> Enum.group_by(& &1.state)
      |> Enum.map(fn {state, rows} -> {state, Enum.reduce(rows, 0, &(&1.count + &2))} end)
      |> Enum.into(%{})

    socket
    |> assign(:stats, stats)
    |> assign(:queues, queues)
    |> assign(:state_counts, state_counts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: monospace; padding: 1rem; background: #111; color: #eee; min-height: 100vh;">
      <h1 style="font-size: 1.5rem; margin-bottom: 1rem;">Oban Jobs</h1>

      <div style="display: flex; gap: 0.5rem; margin-bottom: 1rem; flex-wrap: wrap;">
        <button
          phx-click="filter-state"
          phx-value-state="all"
          style={"padding: 0.25rem 0.75rem; border: 1px solid #555; background: #{if @filter_state == "all", do: "#444", else: "#222"}; color: #eee; cursor: pointer;"}
        >
          all ({Map.values(@state_counts) |> Enum.sum()})
        </button>
        <%= for state <- ~w(available scheduled executing completed retryable discarded cancelled) do %>
          <button
            phx-click="filter-state"
            phx-value-state={state}
            style={"padding: 0.25rem 0.75rem; border: 1px solid #555; background: #{if @filter_state == state, do: "#444", else: "#222"}; color: #{state_color(state)}; cursor: pointer;"}
          >
            {state} ({Map.get(@state_counts, state, 0)})
          </button>
        <% end %>
      </div>

      <div style="display: flex; gap: 0.5rem; margin-bottom: 1rem; flex-wrap: wrap;">
        <button
          phx-click="filter-queue"
          phx-value-queue="all"
          style={"padding: 0.25rem 0.75rem; border: 1px solid #555; background: #{if @filter_queue == "all", do: "#444", else: "#222"}; color: #eee; cursor: pointer;"}
        >
          all queues
        </button>
        <%= for q <- @queues do %>
          <button
            phx-click="filter-queue"
            phx-value-queue={q}
            style={"padding: 0.25rem 0.75rem; border: 1px solid #555; background: #{if @filter_queue == q, do: "#444", else: "#222"}; color: #eee; cursor: pointer;"}
          >
            {q}
          </button>
        <% end %>
      </div>

      <table style="width: 100%; border-collapse: collapse; font-size: 0.8rem;">
        <thead>
          <tr style="border-bottom: 1px solid #444;">
            <th style="text-align: left; padding: 0.5rem;">ID</th>
            <th style="text-align: left; padding: 0.5rem;">State</th>
            <th style="text-align: left; padding: 0.5rem;">Queue</th>
            <th style="text-align: left; padding: 0.5rem;">Worker</th>
            <th style="text-align: left; padding: 0.5rem;">Args</th>
            <th style="text-align: left; padding: 0.5rem;">Attempt</th>
            <th style="text-align: left; padding: 0.5rem;">Inserted</th>
            <th style="text-align: left; padding: 0.5rem;">Actions</th>
          </tr>
        </thead>
        <tbody>
          <%= for job <- @jobs do %>
            <tr style="border-bottom: 1px solid #333;">
              <td style="padding: 0.4rem;">{job.id}</td>
              <td style={"padding: 0.4rem; color: #{state_color(to_string(job.state))};"}>
                {job.state}
              </td>
              <td style="padding: 0.4rem;">{job.queue}</td>
              <td style="padding: 0.4rem;">{short_worker(job.worker)}</td>
              <td style="padding: 0.4rem; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                <span title={Jason.encode!(job.args)}>{summarize_args(job.args)}</span>
              </td>
              <td style="padding: 0.4rem;">{job.attempt}/{job.max_attempts}</td>
              <td style="padding: 0.4rem;">{format_time(job.inserted_at)}</td>
              <td style="padding: 0.4rem; display: flex; gap: 0.25rem;">
                <%= if to_string(job.state) in ~w(retryable discarded) do %>
                  <button
                    phx-click="retry-job"
                    phx-value-id={job.id}
                    style="padding: 0.15rem 0.5rem; background: #353; border: 1px solid #5a5; color: #8f8; cursor: pointer; font-size: 0.7rem;"
                  >
                    retry
                  </button>
                <% end %>
                <%= if to_string(job.state) in ~w(available scheduled executing retryable) do %>
                  <button
                    phx-click="cancel-job"
                    phx-value-id={job.id}
                    style="padding: 0.15rem 0.5rem; background: #533; border: 1px solid #a55; color: #f88; cursor: pointer; font-size: 0.7rem;"
                  >
                    cancel
                  </button>
                <% end %>
                <%= if job.errors != [] do %>
                  <span title={Enum.join(job.errors, "\n\n")} style="color: #f88; cursor: help;">
                    ⚠
                  </span>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <div style="display: flex; gap: 1rem; margin-top: 1rem; align-items: center;">
        <%= if @page > 0 do %>
          <button
            phx-click="prev-page"
            style="padding: 0.25rem 0.75rem; background: #333; border: 1px solid #555; color: #eee; cursor: pointer;"
          >
            ← prev
          </button>
        <% end %>
        <span>page {@page + 1}</span>
        <%= if length(@jobs) == @page_size do %>
          <button
            phx-click="next-page"
            style="padding: 0.25rem 0.75rem; background: #333; border: 1px solid #555; color: #eee; cursor: pointer;"
          >
            next →
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp state_color("available"), do: "#8cf"
  defp state_color("scheduled"), do: "#aaa"
  defp state_color("executing"), do: "#ff0"
  defp state_color("completed"), do: "#8f8"
  defp state_color("retryable"), do: "#fa0"
  defp state_color("discarded"), do: "#f55"
  defp state_color("cancelled"), do: "#888"
  defp state_color(_), do: "#eee"

  defp short_worker(w) do
    w |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end

  defp summarize_args(args) when is_map(args) do
    cond do
      args["prompt"] -> "\"#{String.slice(args["prompt"], 0, 50)}…\""
      args["message_id"] -> "msg:#{args["message_id"]}"
      args["batch_id"] -> "batch:#{args["batch_id"]}"
      true -> Jason.encode!(args) |> String.slice(0, 60)
    end
  end

  defp summarize_args(args), do: inspect(args) |> String.slice(0, 60)

  defp format_time(nil), do: "—"

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
end
