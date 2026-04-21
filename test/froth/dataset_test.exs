defmodule Froth.DatasetTest do
  use ExUnit.Case, async: false

  alias SPARQL.Query.Result

  setup do
    previous_config = Application.get_env(:froth, Froth.Dataset)

    Application.put_env(:froth, Froth.Dataset,
      endpoint: "http://example.test/sparql",
      client_module: Froth.DatasetClientStub,
      query_opts: [request_method: :post, protocol_version: "1.0"]
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:froth, Froth.Dataset, previous_config)
      else
        Application.delete_env(:froth, Froth.Dataset)
      end

      Process.delete(Froth.DatasetClientStub)
      Process.delete({Froth.DatasetClientStub, :select})
      Process.delete({Froth.DatasetClientStub, :ask})
      Process.delete({Froth.DatasetClientStub, :construct})
      Process.delete({Froth.DatasetClientStub, :describe})
    end)

    :ok
  end

  test "sparql/1 dispatches SELECT queries through the endpoint client in raw mode" do
    assert {:ok, %Result{} = result} =
             Froth.Dataset.sparql("SELECT ?s WHERE { ?s ?p ?o }")

    assert result.results == []

    assert_received {:dataset_client_call, :select, query, endpoint, opts}
    assert query == "SELECT ?s WHERE { ?s ?p ?o }"
    assert endpoint == "http://example.test/sparql"
    assert opts[:raw_mode]
    assert opts[:request_method] == :post
    assert opts[:protocol_version] == "1.0"
  end

  test "graph_names/0 returns named graph IRIs from the SPARQL endpoint" do
    Process.put(
      {Froth.DatasetClientStub, :select},
      {:ok,
       Result.new([
         %{"g" => RDF.IRI.new!("http://example.test/graphs/alpha")},
         %{"g" => RDF.IRI.new!("http://example.test/graphs/beta")}
       ])}
    )

    assert {:ok, graph_names} = Froth.Dataset.graph_names()

    assert Enum.map(graph_names, &to_string/1) == [
             "http://example.test/graphs/alpha",
             "http://example.test/graphs/beta"
           ]

    assert_received {:dataset_client_call, :select, query, _, opts}
    assert query =~ "SELECT DISTINCT ?g"
    assert opts[:raw_mode]
  end

  test "statement_count/0 parses integer RDF literals" do
    Process.put(
      {Froth.DatasetClientStub, :select},
      {:ok, Result.new([%{"count" => RDF.XSD.integer(42)}])}
    )

    assert {:ok, 42} = Froth.Dataset.statement_count()

    assert_received {:dataset_client_call, :select, query, _, _}
    assert query =~ "COUNT(*) AS ?count"
  end
end
