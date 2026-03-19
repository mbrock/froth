defmodule Froth.Dataset do
  @moduledoc """
  Thin SPARQL client for the RDF knowledge graph served by Jena.

  The endpoint defaults to `http://localhost:3030/kg/sparql` for the host-run
  Phoenix app and can be overridden with the `FROTH_SPARQL_ENDPOINT`
  environment variable when the app is deployed in a different network
  topology.

      Froth.Dataset.sparql("SELECT ?name WHERE { ?s <http://schema.org/name> ?name }")
      Froth.Dataset.graph_names()
  """

  alias SPARQL.Query
  alias SPARQL.Query.Result

  @default_endpoint "http://localhost:3030/kg/sparql"
  @default_query_options [raw_mode: true, request_method: :post, protocol_version: "1.1"]
  @graph_names_query """
  SELECT DISTINCT ?g
  WHERE { GRAPH ?g { ?s ?p ?o } }
  ORDER BY ?g
  """
  @statement_count_query """
  SELECT (COUNT(*) AS ?count)
  WHERE {
    { ?s ?p ?o }
    UNION
    { GRAPH ?g { ?s ?p ?o } }
  }
  """

  @doc """
  Returns the configured SPARQL query endpoint.
  """
  def endpoint do
    Keyword.get(config(), :endpoint, @default_endpoint)
  end

  @doc """
  Executes a SPARQL query against the configured endpoint.

  Query strings are dispatched via the dedicated `SPARQL.Client` query helpers
  in raw mode so we avoid the limitations of the in-memory SPARQL parser.
  """
  def sparql(query_string, opts \\ []) when is_binary(query_string) do
    with {:ok, form} <- query_form(query_string) do
      run_query(form, query_string, opts)
    end
  end

  @doc """
  Executes a SPARQL `SELECT` query.
  """
  def select(query_string, opts \\ []) when is_binary(query_string) do
    run_query(:select, query_string, opts)
  end

  @doc """
  Executes a SPARQL `ASK` query.
  """
  def ask(query_string, opts \\ []) when is_binary(query_string) do
    run_query(:ask, query_string, opts)
  end

  @doc """
  Executes a SPARQL `CONSTRUCT` query.
  """
  def construct(query_string, opts \\ []) when is_binary(query_string) do
    run_query(:construct, query_string, opts)
  end

  @doc """
  Executes a SPARQL `DESCRIBE` query.
  """
  def describe(query_string, opts \\ []) when is_binary(query_string) do
    run_query(:describe, query_string, opts)
  end

  @doc """
  Returns the named graph IRIs exposed by the endpoint.
  """
  def graph_names(opts \\ []) do
    with {:ok, %Result{results: results}} <- select(@graph_names_query, opts) do
      {:ok, Enum.map(results, &Map.fetch!(&1, "g"))}
    end
  end

  @doc """
  Returns the total number of statements visible to the endpoint.
  """
  def statement_count(opts \\ []) do
    with {:ok, %Result{results: results}} <- select(@statement_count_query, opts),
         {:ok, count} <- count_from_results(results) do
      {:ok, count}
    end
  end

  defp run_query(form, query_string, opts) when form in [:select, :ask, :construct, :describe] do
    endpoint = Keyword.get(opts, :endpoint, endpoint())

    client_opts =
      opts
      |> Keyword.delete(:endpoint)
      |> query_options()

    try do
      apply(client(), form, [query_string, endpoint, client_opts])
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp query_form(query_string) do
    case Query.new(query_string) do
      %Query{form: form} when form in [:select, :ask, :construct, :describe] ->
        {:ok, form}

      {:error, _reason} ->
        detect_query_form(query_string)
    end
  end

  defp detect_query_form(query_string) do
    case query_string |> strip_query_prologue() |> leading_query_form() do
      nil -> {:error, "unsupported SPARQL query form"}
      form -> {:ok, form}
    end
  end

  defp strip_query_prologue(query_string) do
    query_string = String.trim_leading(query_string)

    cond do
      query_string == "" ->
        ""

      match = Regex.run(~r/^#.*(?:\r\n|\r|\n)?/, query_string) ->
        query_string
        |> String.replace_prefix(List.first(match), "")
        |> strip_query_prologue()

      match = Regex.run(~r/^PREFIX\s+[^\s:]*:\s*<[^>]+>\s*/i, query_string) ->
        query_string
        |> String.replace_prefix(List.first(match), "")
        |> strip_query_prologue()

      match = Regex.run(~r/^BASE\s+<[^>]+>\s*/i, query_string) ->
        query_string
        |> String.replace_prefix(List.first(match), "")
        |> strip_query_prologue()

      true ->
        query_string
    end
  end

  defp leading_query_form(query_string) do
    case Regex.run(~r/^(SELECT|ASK|CONSTRUCT|DESCRIBE)\b/i, query_string, capture: :all_but_first) do
      [form] -> query_form_atom(form)
      _ -> nil
    end
  end

  defp query_form_atom(form) do
    case String.upcase(form) do
      "SELECT" -> :select
      "ASK" -> :ask
      "CONSTRUCT" -> :construct
      "DESCRIBE" -> :describe
    end
  end

  defp count_from_results([%{"count" => count} | _]), do: count_value(count)
  defp count_from_results([]), do: {:ok, 0}
  defp count_from_results(_), do: {:error, "count query returned an unexpected result"}

  defp count_value(%RDF.Literal{} = literal) do
    case RDF.Term.value(literal) do
      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {count, ""} -> {:ok, count}
          _ -> {:error, "count query returned a non-integer literal"}
        end

      _ ->
        {:error, "count query returned a non-integer literal"}
    end
  end

  defp count_value(value) when is_integer(value), do: {:ok, value}

  defp count_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> {:ok, count}
      _ -> {:error, "count query returned a non-integer value"}
    end
  end

  defp count_value(_), do: {:error, "count query returned an unexpected value"}

  defp query_options(opts) do
    @default_query_options
    |> Keyword.merge(Keyword.get(config(), :query_opts, []))
    |> Keyword.merge(opts)
  end

  defp client do
    Keyword.get(config(), :client_module, SPARQL.Client)
  end

  defp config do
    Application.get_env(:froth, __MODULE__, [])
  end
end
