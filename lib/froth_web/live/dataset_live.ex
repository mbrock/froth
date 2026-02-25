defmodule FrothWeb.DatasetLive do
  use FrothWeb, :live_view

  alias Froth.Repo
  alias Froth.Replicate.{Collection, Model}

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:view, :collections)
     |> assign(:collection, nil)
     |> assign(:model, nil)
     |> assign(:q, "")
     |> assign(:full_description, nil)
     |> assign(:readme, nil)
     |> load_collections()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params do
        %{"collection" => slug, "model" => model} ->
          socket
          |> assign(:view, :model)
          |> assign(:collection, slug)
          |> assign(:model, model)
          |> load_model(model)

        %{"collection" => slug} ->
          socket
          |> assign(:view, :models)
          |> assign(:collection, slug)
          |> assign(:model, nil)
          |> load_models(slug)

        _ ->
          socket
          |> assign(:view, :collections)
          |> assign(:collection, nil)
          |> assign(:model, nil)
          |> load_collections()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q || "")
    socket = assign(socket, :q, q)

    socket =
      case socket.assigns.view do
        :collections -> load_collections(socket)
        :models -> load_models(socket, socket.assigns.collection)
        _ -> socket
      end

    {:noreply, socket}
  end

  # --- Data loading ---

  defp load_collections(socket) do
    q = socket.assigns[:q] || ""

    collections =
      from(c in Collection,
        left_join: m in Model,
        on: m.collection_slug == c.slug,
        group_by: [c.slug, c.name, c.description],
        select: %{slug: c.slug, name: c.name, description: c.description, count: count(m.name)},
        order_by: [desc: count(m.name)]
      )
      |> Repo.all()
      |> filter_by_q(q, [:name, :slug, :description])

    assign(socket, :items, collections)
  end

  defp load_models(socket, slug) do
    q = socket.assigns[:q] || ""

    full_desc =
      Repo.one(from(c in Collection, where: c.slug == ^slug, select: c.full_description))

    models =
      from(m in Model,
        where: m.collection_slug == ^slug,
        select: %{
          id: fragment("? || '/' || ?", m.owner, m.name),
          name: fragment("? || '/' || ?", m.owner, m.name),
          description: m.description,
          runs: m.run_count,
          official: m.is_official
        },
        order_by: [desc: m.run_count]
      )
      |> Repo.all()
      |> filter_by_q(q, [:name, :description])

    socket
    |> assign(:items, models)
    |> assign(:full_description, full_desc)
  end

  defp load_model(socket, model_id) do
    [owner, name] = String.split(model_id, "/", parts: 2)

    model =
      Repo.one(from(m in Model, where: m.owner == ^owner and m.name == ^name))

    {props, inputs, readme} =
      case model do
        nil ->
          {[], [], nil}

        m ->
          props =
            [
              {"owner", m.owner},
              {"name", m.name},
              {"description", m.description},
              {"run_count", to_string(m.run_count)},
              {"visibility", m.visibility},
              {"is_official", to_string(m.is_official)},
              {"collection", m.collection_slug}
            ]
            |> Enum.concat(
              for {k, v} <- [
                    {"url", m.url},
                    {"cover_image_url", m.cover_image_url},
                    {"github_url", m.github_url},
                    {"license_url", m.license_url},
                    {"paper_url", m.paper_url},
                    {"created_at", m.created_at && to_string(m.created_at)}
                  ],
                  v != nil,
                  do: {k, v}
            )
            |> Enum.map(fn {k, v} -> %{predicate: k, object: v} end)

          inputs =
            case m.input_schema do
              nil ->
                []

              schema ->
                schema
                |> Enum.map(fn {param_name, spec} ->
                  %{
                    name: param_name,
                    type: spec["type"],
                    description: spec["description"],
                    default:
                      case spec["default"] do
                        v when is_binary(v) or is_number(v) or is_boolean(v) -> to_string(v)
                        _ -> nil
                      end
                  }
                end)
                |> Enum.sort_by(& &1.name)
            end

          {props, inputs, m.readme}
      end

    socket
    |> assign(:props, props)
    |> assign(:inputs, inputs)
    |> assign(:readme, readme)
  end

  defp filter_by_q(items, "", _fields), do: items

  defp filter_by_q(items, q, fields) do
    q_down = String.downcase(q)

    Enum.filter(items, fn item ->
      Enum.any?(fields, fn field ->
        item |> Map.get(field, "") |> to_string() |> String.downcase() |> String.contains?(q_down)
      end)
    end)
  end

  defp render_markdown(text) do
    case Earmark.as_html(text) do
      {:ok, html, _} -> html
      _ -> text
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div id="dataset-page" class="min-h-screen bg-black text-white text-[13px]">
        <header class="sticky top-0 z-30 bg-black border-b border-white/10 safe-top">
          <div class="max-w-3xl mx-auto px-3 py-2 flex items-center justify-between gap-3">
            <div class="min-w-0 flex items-center gap-2">
              <.link navigate={~p"/froth/dataset"} class="text-xs text-white/70 hover:text-white">
                Dataset
              </.link>
              <span :if={@collection} class="text-white/30">/</span>
              <.link
                :if={@collection}
                navigate={~p"/froth/dataset?collection=#{@collection}"}
                class="text-xs text-white/70 hover:text-white truncate"
              >
                {@collection}
              </.link>
              <span :if={@model} class="text-white/30">/</span>
              <span :if={@model} class="text-xs text-white/70 truncate">{@model}</span>
            </div>
            <.link
              navigate={~p"/froth"}
              class="text-[11px] text-white/30 hover:text-white/60 shrink-0"
            >
              Back
            </.link>
          </div>
        </header>

        <main class="max-w-3xl mx-auto px-3 pt-3 pb-10">
          <%= case @view do %>
            <% :collections -> %>
              <.search_bar q={@q} count={length(@items)} />
              <.collection_list items={@items} />
            <% :models -> %>
              <div
                :if={@full_description}
                class="mb-4 text-[12px] text-white/50 prose prose-invert prose-sm max-w-none
                prose-headings:text-white/70 prose-headings:text-[13px] prose-headings:mt-3 prose-headings:mb-1
                prose-a:text-white/60 prose-p:my-1 prose-li:my-0"
              >
                {raw(render_markdown(@full_description))}
              </div>
              <.search_bar q={@q} count={length(@items)} />
              <.model_list items={@items} collection={@collection} />
            <% :model -> %>
              <.model_detail props={@props} inputs={@inputs} model={@model} readme={@readme} />
          <% end %>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp search_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mb-3">
      <form phx-change="search" class="flex-1">
        <input
          type="text"
          name="q"
          value={@q}
          autocomplete="off"
          placeholder="Filter…"
          phx-debounce="120"
          class="w-full bg-white/5 text-white text-[12px] px-2.5 py-2 border border-white/10 focus:outline-none focus:border-white/20 placeholder:text-white/20"
        />
      </form>
      <div class="text-[11px] text-white/30 tabular-nums">{@count}</div>
    </div>
    """
  end

  defp collection_list(assigns) do
    ~H"""
    <div class="border border-white/10 overflow-hidden bg-white/2">
      <div :if={@items == []} class="px-3 py-6 text-white/35 text-center">No collections</div>
      <.link
        :for={c <- @items}
        navigate={~p"/froth/dataset?collection=#{c.slug}"}
        class="block px-3 py-2 border-t border-white/10 first:border-t-0 hover:bg-white/5"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="text-[12px] text-white/85">{c.name}</div>
            <div class="text-[10px] text-white/30 truncate">{c.description}</div>
          </div>
          <div class="text-[11px] text-white/35 tabular-nums shrink-0">{c.count}</div>
        </div>
      </.link>
    </div>
    """
  end

  defp model_list(assigns) do
    ~H"""
    <div class="border border-white/10 overflow-hidden bg-white/2">
      <div :if={@items == []} class="px-3 py-6 text-white/35 text-center">No models</div>
      <.link
        :for={m <- @items}
        navigate={~p"/froth/dataset?collection=#{@collection}&model=#{m.id}"}
        class="block px-3 py-2 border-t border-white/10 first:border-t-0 hover:bg-white/5"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="flex items-center gap-1.5">
              <span class="text-[12px] text-white/85">{m.name}</span>
              <span :if={m.official} class="text-[9px] text-green-400/60">official</span>
            </div>
            <div class="text-[10px] text-white/30 truncate">{m.description}</div>
          </div>
          <div class="text-[11px] text-white/35 tabular-nums shrink-0">{format_runs(m.runs)}</div>
        </div>
      </.link>
    </div>
    """
  end

  defp model_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="border border-white/10 overflow-hidden bg-white/2">
        <div class="px-3 py-2 border-b border-white/10 text-[11px] text-white/50">Properties</div>
        <div
          :for={p <- @props}
          class="px-3 py-1.5 border-t border-white/5 first:border-t-0 flex gap-3"
        >
          <div class="text-[11px] text-white/40 w-40 shrink-0 font-mono truncate" title={p.predicate}>
            {p.predicate}
          </div>
          <div class="text-[12px] text-white/80 min-w-0 break-all">{p.object}</div>
        </div>
      </div>

      <div :if={@inputs != []} class="border border-white/10 overflow-hidden bg-white/2">
        <div class="px-3 py-2 border-b border-white/10 text-[11px] text-white/50">
          Input Parameters ({length(@inputs)})
        </div>
        <div :for={i <- @inputs} class="px-3 py-2 border-t border-white/5 first:border-t-0">
          <div class="flex items-center gap-2">
            <span class="text-[12px] text-white/85 font-mono">{i.name}</span>
            <span :if={i.type} class="text-[10px] text-white/30">{i.type}</span>
            <span :if={i.default} class="text-[10px] text-white/20">= {i.default}</span>
          </div>
          <div :if={i.description} class="text-[10px] text-white/30 mt-0.5">{i.description}</div>
        </div>
      </div>

      <div :if={@readme} class="border border-white/10 overflow-hidden bg-white/2">
        <div class="px-3 py-2 border-b border-white/10 text-[11px] text-white/50">README</div>
        <div class="px-3 py-3 prose prose-invert prose-sm max-w-none text-[12px]
          prose-headings:text-white/80 prose-headings:text-[13px] prose-headings:mt-3 prose-headings:mb-1
          prose-a:text-white/60 prose-p:my-1.5 prose-li:my-0.5 prose-code:text-white/70
          prose-pre:bg-white/5 prose-pre:border prose-pre:border-white/10 prose-pre:text-[11px]
          prose-img:max-h-48">
          {raw(render_markdown(@readme))}
        </div>
      </div>
    </div>
    """
  end

  defp format_runs(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp format_runs(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  defp format_runs(n), do: to_string(n)
end
