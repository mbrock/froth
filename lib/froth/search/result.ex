defmodule Froth.Search.Result do
  @moduledoc """
  Result for triangulated multi-provider web search.
  """

  @type source_status :: :ok | :empty | :error | :timeout

  @type source_result :: %{
          status: source_status(),
          text: String.t() | nil,
          citations: [String.t()],
          error: String.t() | nil
        }

  @type t :: %__MODULE__{
          query: String.t(),
          sources: %{optional(atom()) => source_result()},
          collated: String.t() | nil,
          agreement: float(),
          single_source_claims: [String.t()]
        }

  defstruct query: nil,
            sources: %{},
            collated: nil,
            agreement: 0.0,
            single_source_claims: []

  def tool_payload(%__MODULE__{} = result) do
    %{
      "query" => result.query,
      "collated" => result.collated,
      "agreement" => result.agreement,
      "single_source_claims" => result.single_source_claims,
      "citations" => deduped_citations(result),
      "providers" => provider_statuses(result.sources)
    }
  end

  defp deduped_citations(%__MODULE__{sources: sources}) do
    sources
    |> Map.values()
    |> Enum.flat_map(&Map.get(&1, :citations, []))
    |> Enum.uniq()
  end

  defp provider_statuses(sources) when is_map(sources) do
    Map.new(sources, fn {provider, source} ->
      {Atom.to_string(provider),
       %{
         "status" => source.status |> to_string() |> String.trim_leading(":"),
         "citations" => source.citations,
         "error" => source.error
       }}
    end)
  end
end
