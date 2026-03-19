defmodule Froth.DatasetClientStub do
  alias SPARQL.Query.Result

  def select(query, endpoint, opts) do
    record_call(:select, query, endpoint, opts)
    response(:select, {:ok, Result.new([])})
  end

  def ask(query, endpoint, opts) do
    record_call(:ask, query, endpoint, opts)
    response(:ask, {:ok, Result.new(false)})
  end

  def construct(query, endpoint, opts) do
    record_call(:construct, query, endpoint, opts)
    response(:construct, {:ok, RDF.Graph.new()})
  end

  def describe(query, endpoint, opts) do
    record_call(:describe, query, endpoint, opts)
    response(:describe, {:ok, RDF.Graph.new()})
  end

  defp record_call(form, query, endpoint, opts) do
    send(self(), {:dataset_client_call, form, query, endpoint, opts})
  end

  defp response(form, default) do
    Process.get({__MODULE__, form}, Process.get(__MODULE__, default))
  end
end
