defmodule FrothWeb.AnalysesLive do
  use FrothWeb, :live_view

  import Ecto.Query

  @youtube_re ~r{(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]+)}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:days, available_days())
     |> assign(:day, Date.utc_today())
     |> assign(:analyses, [])}
  end

  @impl true
  def handle_params(%{"day" => day_str}, _uri, socket) do
    case Date.from_iso8601(day_str) do
      {:ok, day} ->
        {:noreply, socket |> assign(:day, day) |> load_analyses(day)}

      _ ->
        {:noreply,
         push_patch(socket, to: ~p"/froth/analyses/#{Date.to_iso8601(Date.utc_today())}")}
    end
  end

  def handle_params(_params, _uri, socket) do
    day = List.first(socket.assigns.days) || Date.utc_today()
    {:noreply, socket |> assign(:day, day) |> load_analyses(day)}
  end

  @impl true
  def handle_event("prev", _, socket) do
    day = Date.add(socket.assigns.day, -1)
    {:noreply, push_patch(socket, to: ~p"/froth/analyses/#{Date.to_iso8601(day)}")}
  end

  def handle_event("next", _, socket) do
    day = Date.add(socket.assigns.day, 1)
    {:noreply, push_patch(socket, to: ~p"/froth/analyses/#{Date.to_iso8601(day)}")}
  end

  defp day_bounds(day) do
    start_unix = day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    end_unix = day |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    {start_unix, end_unix}
  end

  defp load_analyses(socket, day) do
    {start_unix, end_unix} = day_bounds(day)

    analyses =
      from(a in Froth.Analysis,
        join: m in "telegram_messages",
        on: m.chat_id == a.chat_id and m.message_id == a.message_id,
        where: m.date >= ^start_unix and m.date < ^end_unix,
        order_by: [desc: m.date],
        select: %{a | metadata: a.metadata},
        select_merge: %{generated_at: a.generated_at}
      )
      |> Froth.Repo.all()
      |> Enum.uniq_by(fn a -> {a.type, a.chat_id, a.message_id} end)
      |> Enum.map(fn a ->
        {:ok, html, _} = Earmark.as_html(a.analysis_text)
        Map.put(a, :html, html)
      end)

    assign(socket, :analyses, analyses)
  end

  defp available_days do
    from(m in "telegram_messages",
      join: a in Froth.Analysis,
      on: a.chat_id == m.chat_id and a.message_id == m.message_id,
      select: fragment("DISTINCT date(to_timestamp(?))", m.date),
      order_by: [desc: fragment("date(to_timestamp(?))", m.date)]
    )
    |> Froth.Repo.all()
  end

  defp title(a) do
    case a.metadata do
      %{"filename" => f} when f != "" -> f
      _ -> "#{a.type} analysis"
    end
  end

  defp youtube_id(a) do
    case a.metadata do
      %{"video_url" => url} ->
        case Regex.run(@youtube_re, url) do
          [_, id] -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div id="analyses-page" class="max-w-2xl mx-auto py-6 px-4">
        <div class="flex items-center gap-4 mb-6">
          <button phx-click="prev" class="text-neutral-400 hover:text-white px-2">&larr;</button>
          <h1 class="text-xl font-bold">{Calendar.strftime(@day, "%A, %B %d")}</h1>
          <button phx-click="next" class="text-neutral-400 hover:text-white px-2">&rarr;</button>
          <.link navigate={~p"/froth/inference"} class="text-xs text-neutral-500 hover:text-white">
            inference
          </.link>
          <.link navigate={~p"/froth/dataset"} class="text-xs text-neutral-500 hover:text-white">
            dataset
          </.link>
          <.link navigate={~p"/froth/rdf"} class="text-xs text-neutral-500 hover:text-white">
            rdf
          </.link>
          <span class="text-xs text-neutral-500 ml-auto">{length(@analyses)} analyses</span>
        </div>

        <div class="flex flex-wrap gap-1 mb-6">
          <.link
            :for={d <- @days}
            navigate={~p"/froth/analyses/#{Date.to_iso8601(d)}"}
            class={"text-xs px-2 py-0.5 #{if d == @day, do: "bg-white text-black", else: "text-neutral-500 hover:text-white"}"}
          >
            {Calendar.strftime(d, "%b %d")}
          </.link>
        </div>

        <div :for={a <- @analyses} class="mb-4 border-b border-neutral-800 pb-4">
          <details>
            <summary class="cursor-pointer py-1 flex items-center gap-3">
              <img
                :if={a.type == "image"}
                src={~p"/froth/media/#{a.chat_id}/#{a.message_id}"}
                class="w-12 h-12 object-cover"
                loading="lazy"
              />
              <div
                :if={a.type == "youtube" && youtube_id(a)}
                class="w-12 h-12 bg-neutral-800 flex items-center justify-center text-red-500 text-lg"
              >
                ▶
              </div>
              <span class="text-xs text-neutral-500">{a.type}</span>
              <span>{title(a)}</span>
            </summary>
            <div class="pt-3 pb-2">
              <img
                :if={a.type == "image"}
                src={~p"/froth/media/#{a.chat_id}/#{a.message_id}"}
                class="max-w-full mb-3"
                loading="lazy"
              />
              <iframe
                :if={a.type == "youtube" && youtube_id(a)}
                src={"https://www.youtube.com/embed/#{youtube_id(a)}"}
                class="w-full aspect-video mb-3"
                allowfullscreen
                loading="lazy"
              >
              </iframe>
              <div class="md-prose text-sm text-neutral-200 leading-relaxed">
                {Phoenix.HTML.raw(a.html)}
              </div>
            </div>
          </details>
        </div>

        <div :if={@analyses == []} class="text-neutral-500 text-center py-12">
          No analyses for this day.
        </div>
      </div>
    </Layouts.app>
    """
  end
end
