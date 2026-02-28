defmodule Froth.Dataset do
  @moduledoc """
  GenServer holding an RDF.Dataset in memory.

  On startup, auto-loads all datasets stored in the `datasets` table.

      Froth.Dataset.load("@prefix ex: <http://example.org/> . ex:s ex:p ex:o .")
      Froth.Dataset.query({:_, ~I<http://schema.org/name>, :name?})
      Froth.Dataset.sparql("SELECT ?name WHERE { ?s <http://schema.org/name> ?name }")
      Froth.Dataset.graph_names()
  """

  use GenServer

  alias Froth.Telemetry.Span

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Parse a TriG/Turtle string and replace the in-memory dataset with the result.

  Returns `{:ok, %{statements: n, graphs: n}}` or `{:error, reason}`.
  """
  def load(trig_string) when is_binary(trig_string) do
    GenServer.call(__MODULE__, {:load, trig_string}, :infinity)
  end

  @doc """
  Query the default graph with a triple pattern via `RDF.Query.execute/2`.

  Pattern is a tuple of subject, predicate, object where:
  - Atoms ending in `?` are variables (e.g. `:name?`)
  - `:_` is a wildcard
  - IRIs use the `~I` sigil

      Froth.Dataset.query({:_, ~I<http://schema.org/name>, :name?})
  """
  def query(pattern) do
    GenServer.call(__MODULE__, {:query, pattern}, :infinity)
  end

  @doc """
  Run a SPARQL SELECT or CONSTRUCT query against all graphs merged.

  Returns `{:ok, %SPARQL.Query.Result{results: [%{"var" => value}, ...]}}` or
  `{:error, reason}`.

  Supported: SELECT, CONSTRUCT, OPTIONAL, UNION, FILTER, BIND, MINUS, DISTINCT, REDUCED.
  NOT supported: LIMIT, ORDER BY, OFFSET, GROUP BY, aggregates, subqueries,
  property paths, ASK, DESCRIBE, VALUES, GRAPH, FROM.

      Froth.Dataset.sparql("SELECT ?name WHERE { ?s <http://schema.org/name> ?name }")
  """
  def sparql(query_string) when is_binary(query_string) do
    GenServer.call(__MODULE__, {:sparql, query_string}, :infinity)
  end

  @doc """
  Return the list of named graph IRIs in the dataset.
  """
  def graph_names do
    GenServer.call(__MODULE__, :graph_names)
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    {:ok, %{dataset: RDF.Dataset.new()}, {:continue, :auto_load}}
  end

  @impl true
  def handle_continue(:auto_load, state) do
    import Ecto.Query

    stored =
      Froth.Repo.all(from(d in Froth.Dataset.Stored, select: %{name: d.name, data: d.data}))

    dataset =
      Enum.reduce(stored, state.dataset, fn %{name: name, data: data}, ds ->
        t0 = System.monotonic_time(:millisecond)

        case RDF.TriG.read_string(data) do
          {:ok, parsed} ->
            merged = RDF.Dataset.add(ds, parsed)
            elapsed = System.monotonic_time(:millisecond) - t0
            count = RDF.Dataset.statement_count(parsed)

            Span.execute([:froth, :dataset, :auto_loaded], nil, %{
              name: name,
              triples: count,
              elapsed_ms: elapsed
            })

            merged

          {:error, reason} ->
            Span.execute([:froth, :dataset, :auto_load_failed], nil, %{name: name, reason: reason})

            ds
        end
      end)

    total = RDF.Dataset.statement_count(dataset)

    Span.execute([:froth, :dataset, :auto_load_complete], nil, %{
      datasets: length(stored),
      total_triples: total
    })

    {:noreply, %{state | dataset: dataset}}
  end

  @impl true
  def handle_call({:load, trig_string}, _from, state) do
    t0 = System.monotonic_time(:millisecond)

    case RDF.TriG.read_string(trig_string) do
      {:ok, dataset} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        count = RDF.Dataset.statement_count(dataset)
        names = RDF.Dataset.graph_names(dataset)

        Span.execute([:froth, :dataset, :loaded], nil, %{
          count: count,
          graphs: length(names),
          elapsed_ms: elapsed
        })

        {:reply, {:ok, %{statements: count, graphs: length(names)}}, %{state | dataset: dataset}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, pattern}, _from, %{dataset: ds} = state) do
    graph = RDF.Dataset.default_graph(ds)

    try do
      {:reply, RDF.Query.execute(pattern, graph), state}
    rescue
      e -> {:reply, {:error, Exception.message(e)}, state}
    end
  end

  def handle_call({:sparql, query_string}, _from, %{dataset: ds} = state) do
    try do
      query = SPARQL.query(query_string)
      # Merge all named graphs into one for querying — the SPARQL lib
      # doesn't handle GRAPH patterns on datasets well
      merged =
        ds
        |> RDF.Dataset.graphs()
        |> Enum.reduce(RDF.Graph.new(), &RDF.Graph.add(&2, &1))

      {:reply, {:ok, SPARQL.execute_query(merged, query)}, state}
    rescue
      e -> {:reply, {:error, Exception.message(e)}, state}
    end
  end

  def handle_call(:graph_names, _from, %{dataset: ds} = state) do
    {:reply, RDF.Dataset.graph_names(ds), state}
  end
end
