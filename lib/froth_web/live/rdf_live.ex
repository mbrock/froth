defmodule FrothWeb.RdfLive do
  use FrothWeb, :live_view

  @prefixes %{
    "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
    "xsd" => "http://www.w3.org/2001/XMLSchema#",
    "schema" => "http://schema.org/",
    "rep" => "https://replicate.com/ontology/",
    "gh" => "https://github.com/",
    "ghont" => "https://github.com/ontology/"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       subject: nil,
       data: nil,
       expanded: MapSet.new(),
       labels: load_predicate_labels()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params do
      %{"iri" => iri} ->
        data = load_resource(iri)
        refs = load_back_refs(iri)
        {:noreply, assign(socket, subject: iri, data: data, refs: refs)}

      _ ->
        # Show root: list of types with counts
        types = load_types()
        {:noreply, assign(socket, subject: nil, data: nil, types: types, refs: [])}
    end
  end

  @impl true
  def handle_event("expand", %{"iri" => iri}, socket) do
    expanded = MapSet.put(socket.assigns.expanded, iri)
    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("collapse", %{"iri" => iri}, socket) do
    expanded = MapSet.delete(socket.assigns.expanded, iri)
    {:noreply, assign(socket, :expanded, expanded)}
  end

  # --- Data loading ---

  defp load_resource(iri) do
    case sparql("SELECT ?p ?o WHERE { <#{iri}> ?p ?o }") do
      {:ok, results} ->
        {type, props} =
          Enum.reduce(results, {nil, []}, fn row, {type, props} ->
            p = to_string(row["p"])
            o = row["o"]

            if p == "http://www.w3.org/1999/02/22-rdf-syntax-ns#type" do
              {o, props}
            else
              {type, [{p, o} | props]}
            end
          end)

        # Sort: literals first, then URIs, then by predicate
        props =
          Enum.sort_by(props, fn {p, o} ->
            {not is_literal?(o), is_bnode?(o), p}
          end)

        %{type: type, props: props}

      _ ->
        %{type: nil, props: []}
    end
  end

  defp load_predicate_labels do
    case sparql(
           "SELECT ?s ?label WHERE { ?s <http://www.w3.org/2000/01/rdf-schema#label> ?label }"
         ) do
      {:ok, results} ->
        Map.new(results, fn r -> {to_string(r["s"]), to_string(RDF.Term.value(r["label"]))} end)

      _ ->
        %{}
    end
  end

  defp load_types do
    case sparql("SELECT ?s ?type WHERE { ?s a ?type }") do
      {:ok, results} ->
        results
        |> Enum.group_by(fn r -> to_string(r["type"]) end)
        |> Enum.map(fn {type, items} -> %{iri: type, count: length(items)} end)
        |> Enum.sort_by(& &1.count, :desc)

      _ ->
        []
    end
  end

  defp load_back_refs(iri) do
    case sparql("SELECT ?s ?p WHERE { ?s ?p <#{iri}> }") do
      {:ok, results} -> results
      _ -> []
    end
  end

  defp sparql(q) do
    case Froth.Dataset.sparql(q) do
      {:ok, %{results: results}} -> {:ok, results}
      err -> err
    end
  end

  # --- Value helpers ---

  defp is_literal?(%RDF.Literal{}), do: true
  defp is_literal?(_), do: false

  defp is_bnode?(%RDF.BlankNode{}), do: true
  defp is_bnode?(_), do: false

  defp curie_prefix(iri) when is_binary(iri) do
    Enum.find_value(@prefixes, nil, fn {prefix, ns} ->
      if String.starts_with?(iri, ns), do: prefix
    end)
  end

  defp curie_local(iri) when is_binary(iri) do
    Enum.find_value(@prefixes, iri, fn {_prefix, ns} ->
      if String.starts_with?(iri, ns) do
        String.replace_prefix(iri, ns, "")
      end
    end)
  end

  defp value_string(%RDF.Literal{} = lit), do: to_string(RDF.Term.value(lit))
  defp value_string(other), do: to_string(other)

  defp literal_type(%RDF.Literal{literal: %RDF.XSD.Integer{}}), do: :integer
  defp literal_type(%RDF.Literal{literal: %RDF.XSD.Double{}}), do: :double
  defp literal_type(%RDF.Literal{literal: %RDF.XSD.Decimal{}}), do: :decimal
  defp literal_type(%RDF.Literal{literal: %RDF.XSD.Boolean{}}), do: :boolean
  defp literal_type(%RDF.Literal{literal: %RDF.XSD.DateTime{}}), do: :datetime
  defp literal_type(%RDF.Literal{literal: %RDF.XSD.Date{}}), do: :date
  defp literal_type(%RDF.Literal{}), do: :string
  defp literal_type(_), do: nil

  defp iri_path(iri) when is_binary(iri), do: ~p"/froth/rdf?iri=#{iri}"
  defp iri_path(%RDF.IRI{} = iri), do: iri_path(to_string(iri))

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div id="rdf-page" class="min-h-screen bg-black text-white text-[13px]">
        <header class="sticky top-0 z-30 bg-black border-b border-white/10">
          <div class="max-w-4xl mx-auto px-3 py-2 flex items-center justify-between gap-3">
            <.link navigate={~p"/froth/rdf"} class="text-xs text-white/70 hover:text-white">
              RDF
            </.link>
            <.link navigate={~p"/froth"} class="text-[11px] text-white/30 hover:text-white/60">
              Back
            </.link>
          </div>
        </header>

        <main class="max-w-4xl mx-auto px-3 pt-3 pb-10">
          <%= if @subject do %>
            <.resource iri={@subject} data={@data} expanded={@expanded} labels={@labels} refs={@refs} />
          <% else %>
            <.type_index types={@types} />
          <% end %>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp type_index(assigns) do
    ~H"""
    <div class="border border-white/10 bg-white/2">
      <div class="px-3 py-2 border-b border-white/10 text-[11px] text-white/50">
        Types ({length(@types)})
      </div>
      <.link
        :for={t <- @types}
        navigate={iri_path(t.iri)}
        class="block px-3 py-1.5 border-t border-white/5 first:border-t-0 hover:bg-white/5"
      >
        <div class="flex items-center justify-between gap-3">
          <.iri_value iri={t.iri} />
          <span class="text-[11px] text-white/35 tabular-nums">{t.count}</span>
        </div>
      </.link>
    </div>
    """
  end

  defp resource(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center gap-2 text-[11px] text-white/40 font-mono break-all">
        <.iri_value iri={@iri} />
        <span :if={@data && @data.type} class="text-white/25">a</span>
        <.iri_value :if={@data && @data.type} iri={to_string(@data.type)} />
      </div>

      <dl
        :if={@data}
        class="flex flex-row flex-wrap gap-x-6 gap-y-3 border border-white/10 bg-white/2 px-3 py-3"
      >
        <.property
          :for={{pred, obj} <- @data.props}
          pred={pred}
          obj={obj}
          expanded={@expanded}
          labels={@labels}
        />
      </dl>

      <.back_refs refs={@refs} />
    </div>
    """
  end

  defp back_refs(assigns) do
    ~H"""
    <div :if={@refs != []} class="border border-white/10 bg-white/2">
      <div class="px-3 py-2 border-b border-white/10 text-[11px] text-white/50">
        Referenced by ({length(@refs)})
      </div>
      <div :for={r <- @refs} class="px-3 py-1.5 border-t border-white/5 first:border-t-0 flex gap-3">
        <div class="text-[11px] text-white/30 shrink-0">
          <.iri_value iri={to_string(r["p"])} />
        </div>
        <.link navigate={iri_path(to_string(r["s"]))} class="min-w-0 truncate hover:text-white/90">
          <.iri_value iri={to_string(r["s"])} />
        </.link>
      </div>
    </div>
    """
  end

  defp property(assigns) do
    label = Map.get(assigns.labels, assigns.pred)
    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="flex flex-col">
      <dt class="text-[11px] text-white/30" title={@pred}>
        <%= if @label do %>
          <span>{@label}</span>
        <% else %>
          <.iri_value iri={@pred} />
        <% end %>
      </dt>
      <dd class="min-w-0 break-words">
        <.rdf_value obj={@obj} pred={@pred} expanded={@expanded} labels={@labels} />
      </dd>
    </div>
    """
  end

  defp rdf_value(%{obj: %RDF.IRI{}, pred: pred} = assigns)
       when pred in [
              "http://schema.org/image"
            ] do
    iri = to_string(assigns.obj)
    assigns = assign(assigns, :iri, iri)

    ~H"""
    <div class="flex flex-col gap-1">
      <img src={@iri} class="max-h-48 object-contain" loading="lazy" />
    </div>
    """
  end

  defp rdf_value(%{obj: %RDF.IRI{}} = assigns) do
    iri = to_string(assigns.obj)

    is_image =
      String.match?(iri, ~r/\.(jpg|jpeg|png|gif|webp|svg)(\?|$)/i) or
        String.contains?(iri, "replicate.delivery")

    assigns = assign(assigns, iri: iri, is_image: is_image)

    ~H"""
    <%= if @is_image do %>
      <div class="flex flex-col gap-1">
        <img src={@iri} class="max-h-48 object-contain" loading="lazy" />
      </div>
    <% else %>
      <.link navigate={iri_path(@iri)} class="hover:text-white/90">
        <.iri_value iri={@iri} />
      </.link>
    <% end %>
    """
  end

  defp rdf_value(%{obj: %RDF.Literal{}} = assigns) do
    type = literal_type(assigns.obj)
    val = value_string(assigns.obj)
    assigns = assign(assigns, type: type, val: val)

    ~H"""
    <.literal_value type={@type} val={@val} />
    """
  end

  defp rdf_value(%{obj: %RDF.BlankNode{}} = assigns) do
    bnode_id = to_string(assigns.obj)
    is_expanded = MapSet.member?(assigns.expanded, bnode_id)
    labels = Map.get(assigns, :labels, %{})

    bnode_data =
      if is_expanded do
        case sparql("SELECT ?p ?o WHERE { _:#{bnode_id} ?p ?o }") do
          {:ok, results} ->
            Enum.map(results, fn r -> {to_string(r["p"]), r["o"]} end)
            |> Enum.sort_by(fn {p, o} -> {not is_literal?(o), p} end)

          _ ->
            []
        end
      end

    assigns =
      assign(assigns,
        bnode_id: bnode_id,
        is_expanded: is_expanded,
        bnode_data: bnode_data,
        labels: labels
      )

    ~H"""
    <%= if @is_expanded do %>
      <div class="border-l border-white/10 pl-3 mt-1">
        <button
          phx-click="collapse"
          phx-value-iri={@bnode_id}
          class="text-[10px] text-white/25 hover:text-white/50 mb-1"
        >
          collapse
        </button>
        <dl class="flex flex-row flex-wrap gap-x-6 gap-y-2">
          <div :for={{pred, obj} <- @bnode_data} class="flex flex-col">
            <dt class="text-[11px] text-white/30" title={pred}>
              <%= if @labels[pred] do %>
                <span>{@labels[pred]}</span>
              <% else %>
                <.iri_value iri={pred} />
              <% end %>
            </dt>
            <dd class="min-w-0 break-words">
              <.rdf_value obj={obj} pred={pred} expanded={@expanded} labels={@labels} />
            </dd>
          </div>
        </dl>
      </div>
    <% else %>
      <button
        phx-click="expand"
        phx-value-iri={@bnode_id}
        class="text-cyan-500/60 hover:text-cyan-400 text-[11px] font-mono"
      >
        &#9671;
      </button>
    <% end %>
    """
  end

  defp rdf_value(assigns) do
    val = to_string(assigns.obj)
    assigns = assign(assigns, :val, val)

    ~H"""
    <span class="text-white/50">{@val}</span>
    """
  end

  defp iri_value(assigns) do
    iri = assigns.iri
    prefix = curie_prefix(iri)
    local = curie_local(iri)
    assigns = assign(assigns, prefix: prefix, local: local)

    ~H"""
    <%= if @prefix do %>
      <span class="font-mono">
        <span class="text-white/25">{@prefix}:</span><span class="text-blue-400/80">{@local}</span>
      </span>
    <% else %>
      <span class="font-mono text-blue-400/80 truncate" title={@iri}>{@iri}</span>
    <% end %>
    """
  end

  defp literal_value(%{type: :integer} = assigns) do
    ~H"""
    <span class="font-mono text-purple-400/80">{@val}</span>
    """
  end

  defp literal_value(%{type: :double} = assigns) do
    ~H"""
    <span class="font-mono text-blue-400/80">{@val}</span>
    """
  end

  defp literal_value(%{type: :decimal} = assigns) do
    ~H"""
    <span class="font-mono text-indigo-400/80">{@val}</span>
    """
  end

  defp literal_value(%{type: :boolean} = assigns) do
    ~H"""
    <span class="font-bold text-yellow-400/80">{@val}</span>
    """
  end

  defp literal_value(%{type: :datetime} = assigns) do
    ~H"""
    <span class="text-pink-400/80">{@val}</span>
    """
  end

  defp literal_value(%{type: :date} = assigns) do
    ~H"""
    <span class="text-pink-400/80">{@val}</span>
    """
  end

  defp literal_value(%{type: :string} = assigns) do
    is_url = String.starts_with?(assigns.val, "http")
    is_long = String.length(assigns.val) > 200
    assigns = assign(assigns, is_url: is_url, is_long: is_long)

    ~H"""
    <%= cond do %>
      <% @is_url -> %>
        <a
          href={@val}
          target="_blank"
          class="text-blue-400/80 font-mono truncate block hover:text-blue-300"
        >
          {@val}
        </a>
      <% @is_long -> %>
        <details>
          <summary class="text-emerald-400/70 cursor-pointer">
            <span class="font-mono">{String.slice(@val, 0, 120)}…</span>
          </summary>
          <pre class="mt-1 text-[11px] text-emerald-400/70 whitespace-pre-wrap break-words max-h-96 overflow-y-auto border border-white/5 bg-white/2 p-2">{@val}</pre>
        </details>
      <% true -> %>
        <span class="text-emerald-400/70">{@val}</span>
    <% end %>
    """
  end

  defp literal_value(assigns) do
    ~H"""
    <span class="text-orange-400/70">{@val}</span>
    """
  end
end
