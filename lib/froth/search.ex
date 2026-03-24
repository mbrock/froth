defmodule Froth.Search do
  @moduledoc """
  Triangulated web search via multi-provider fan-out.

  Sends the same query to Grok, OpenAI, and Gemini simultaneously,
  then collates results with a fourth LLM call.
  """

  alias Froth.LLM
  alias Froth.LLM.Message
  alias Froth.Search.Result

  @default_timeout 30_000
  @default_collation_model "claude-sonnet-4-20250514"
  @source_text_limit 8_000

  @providers [
    {:grok, Froth.Search.Grok, "grok-4-1-fast-reasoning"},
    {:openai, Froth.Search.OpenAI, "gpt-5.4"},
    {:gemini, Froth.Search.Gemini, "gemini-3.1-pro"}
  ]

  @type provider_name :: :grok | :openai | :gemini

  @doc false
  def provider_system_prompt do
    """
    Use the enabled native web search tools when they improve factual grounding.
    Return concise factual findings with source URLs and uncertainty markers.
    """
  end

  @doc false
  def provider_prompt(query) when is_binary(query) do
    """
    Search the web for: #{String.trim(query)}

    Return:
    1. Direct factual findings with source URLs
    2. Dates and timestamps where available
    3. Explicit uncertainty markers where results are thin
    4. If this is about a social media post, include the full text of the post
    """
  end

  def search(query, opts \\ []), do: query(query, opts)

  def query(query, opts \\ [])

  def query(query, opts) when is_binary(query) and is_list(opts) do
    with {:ok, normalized_query} <- normalize_query(query),
         {:ok, providers} <- selected_providers(opts),
         sources <- fan_out(normalized_query, providers, opts),
         true <- collatable_sources?(sources) or {:error, "all providers failed"} do
      result = %Result{query: normalized_query, sources: sources}

      if Keyword.get(opts, :collate, true) do
        {:ok, collate_result(result, opts)}
      else
        {:ok, result}
      end
    end
  end

  def query(_query, _opts), do: {:error, "query must be a non-empty string"}

  defp normalize_query(query) when is_binary(query) do
    query = String.trim(query)
    if query == "", do: {:error, "query must be a non-empty string"}, else: {:ok, query}
  end

  defp fan_out(query, providers, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    providers
    |> Task.async_stream(
      fn {_name, module, model} ->
        module.search(query, model: model)
      end,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(providers)
    |> Map.new(fn {task_result, {name, _module, _model}} ->
      {name, normalize_provider_result(task_result)}
    end)
  end

  defp normalize_provider_result({:ok, {:ok, %{} = result}}), do: successful_source(result)

  defp normalize_provider_result({:ok, {:ok, text}}) when is_binary(text),
    do: successful_source(%{text: text})

  defp normalize_provider_result({:ok, {:error, reason}}), do: failed_source(:error, reason)

  defp normalize_provider_result({:exit, :timeout}),
    do: failed_source(:timeout, "provider timed out")

  defp normalize_provider_result({:exit, {:timeout, _}}),
    do: failed_source(:timeout, "provider timed out")

  defp normalize_provider_result({:exit, reason}), do: failed_source(:error, reason)
  defp normalize_provider_result(other), do: failed_source(:error, other)

  defp successful_source(%{text: text} = result) when is_binary(text) do
    text = String.trim(text)

    citations =
      text
      |> extract_citations()
      |> Kernel.++(
        normalize_string_list(Map.get(result, :citations) || Map.get(result, "citations"))
      )
      |> Enum.uniq()

    %{
      status: if(text == "", do: :empty, else: :ok),
      text: if(text == "", do: nil, else: text),
      citations: citations,
      error: nil
    }
  end

  defp successful_source(%{"text" => text} = result) when is_binary(text) do
    successful_source(%{text: text, citations: Map.get(result, "citations")})
  end

  defp successful_source(_result), do: %{status: :empty, text: nil, citations: [], error: nil}

  defp failed_source(status, reason) when status in [:error, :timeout] do
    %{
      status: status,
      text: nil,
      citations: [],
      error: format_reason(reason)
    }
  end

  defp collatable_sources?(sources) when is_map(sources) do
    Enum.any?(sources, fn {_provider, source} -> source.status in [:ok, :empty] end)
  end

  defp collate_result(%Result{} = result, opts) do
    case collate(result, opts) do
      {:ok, collated} ->
        %Result{
          result
          | collated: collated.collated,
            agreement: collated.agreement,
            single_source_claims: collated.single_source_claims
        }

      {:error, _reason} ->
        %Result{
          result
          | collated: fallback_collated_text(result),
            agreement: 0.0,
            single_source_claims: []
        }
    end
  end

  defp collate(%Result{} = result, opts) do
    model = Keyword.get(opts, :collation_model, @default_collation_model)

    with {:ok, response} <-
           LLM.stream_single(
             [Message.user(collation_prompt(result))],
             fn _event -> :ok end,
             provider: :anthropic,
             model: model,
             system: collation_system_prompt(),
             max_tokens: 4_096
           ),
         {:ok, parsed} <- parse_collation_response(response.text) do
      {:ok, parsed}
    end
  end

  defp parse_collation_response(text) when is_binary(text) do
    with {:ok, decoded} <- decode_json_object(text),
         collated when is_binary(collated) and collated != "" <- Map.get(decoded, "collated") do
      {:ok,
       %{
         collated: collated,
         agreement: normalize_agreement(Map.get(decoded, "agreement")),
         single_source_claims: normalize_string_list(Map.get(decoded, "single_source_claims"))
       }}
    else
      _ -> {:error, "invalid collation response"}
    end
  end

  defp parse_collation_response(_text), do: {:error, "invalid collation response"}

  defp decode_json_object(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      _ ->
        case Regex.run(~r/\{.*\}/s, text) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp fallback_collated_text(%Result{} = result) do
    available =
      result.sources
      |> Enum.filter(fn {_provider, source} -> is_binary(source.text) and source.text != "" end)
      |> Enum.map_join("\n\n", fn {provider, source} ->
        "#{provider_label(provider)}:\n#{truncate_source_text(source.text)}"
      end)

    gaps =
      result.sources
      |> Enum.filter(fn {_provider, source} -> source.status in [:error, :timeout, :empty] end)
      |> Enum.map_join("; ", fn {provider, source} ->
        case source.status do
          :empty -> "#{provider_label(provider)} returned no useful findings"
          :timeout -> "#{provider_label(provider)} timed out"
          :error -> "#{provider_label(provider)} failed: #{source.error || "unknown error"}"
        end
      end)

    [available, if(gaps != "", do: "Gaps: #{gaps}")]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp collation_system_prompt do
    """
    Return JSON only. No markdown fences.
    """
  end

  defp collation_prompt(%Result{} = result) do
    """
    You received independent web search results for
    the query: #{result.query}

    #{formatted_sources(result.sources)}

    Synthesize a single answer:
    - Facts confirmed by 2+ sources: state as confirmed
    - Facts from only one source: state with attribution
    - Contradictions between sources: state the contradiction
    - Source URLs: deduplicate and list
    - If any source found nothing: note the gap

    Be concise. The caller is an agent, not a human.

    Return JSON with this exact shape:
    {
      "collated": "string",
      "agreement": 0.0,
      "single_source_claims": ["string"]
    }
    """
  end

  defp formatted_sources(sources) when is_map(sources) do
    @providers
    |> Enum.filter(fn {provider, _module, _model} -> Map.has_key?(sources, provider) end)
    |> Enum.map(fn {provider, _module, _model} ->
      formatted_source(provider, Map.get(sources, provider))
    end)
    |> Enum.join("\n\n")
  end

  defp formatted_source(provider, nil),
    do: formatted_source(provider, failed_source(:error, "missing result"))

  defp formatted_source(provider, source) do
    body =
      case source.status do
        :ok ->
          """
          status: ok
          citations: #{format_citation_list(source.citations)}
          text:
          #{truncate_source_text(source.text || "")}
          """

        :empty ->
          "status: empty\nnote: provider found no useful grounded output"

        :timeout ->
          "status: timeout\nnote: #{source.error || "provider timed out"}"

        :error ->
          "status: error\nnote: #{source.error || "provider failed"}"
      end

    "Source #{provider_label(provider)}:\n#{body}"
  end

  defp format_citation_list([]), do: "[]"
  defp format_citation_list(citations), do: Enum.join(citations, ", ")

  defp truncate_source_text(text) when is_binary(text) do
    if String.length(text) <= @source_text_limit do
      text
    else
      String.slice(text, 0, @source_text_limit) <> "\n[truncated]"
    end
  end

  defp truncate_source_text(_text), do: ""

  defp normalize_agreement(value) when is_integer(value), do: normalize_agreement(value * 1.0)

  defp normalize_agreement(value) when is_float(value) do
    value
    |> max(0.0)
    |> min(1.0)
  end

  defp normalize_agreement(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_agreement(parsed)
      _ -> 0.0
    end
  end

  defp normalize_agreement(_value), do: 0.0

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_string_item(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string_item(value), do: normalize_string_item(inspect(value))

  defp selected_providers(opts) when is_list(opts) do
    requested =
      opts
      |> Keyword.get(:providers, Enum.map(@providers, &elem(&1, 0)))
      |> List.wrap()
      |> Enum.map(&normalize_provider_name/1)

    unknown =
      Enum.reject(requested, fn provider ->
        Enum.any?(@providers, &(elem(&1, 0) == provider))
      end)

    if unknown == [] do
      {:ok,
       Enum.filter(@providers, fn {provider, _module, _model} ->
         provider in requested
       end)}
    else
      {:error, "unknown providers: #{Enum.map_join(unknown, ", ", &inspect/1)}"}
    end
  end

  defp normalize_provider_name(provider) when provider in [:grok, :openai, :gemini], do: provider

  defp normalize_provider_name(provider) when is_binary(provider) do
    case String.downcase(String.trim(provider)) do
      "grok" -> :grok
      "openai" -> :openai
      "gpt" -> :openai
      "gemini" -> :gemini
      "google" -> :gemini
      other -> {:unknown, other}
    end
  end

  defp normalize_provider_name(other), do: other

  defp provider_label(:grok), do: "A (Grok/xAI)"
  defp provider_label(:openai), do: "B (GPT/OpenAI)"
  defp provider_label(:gemini), do: "C (Gemini/Google)"
  defp provider_label(provider), do: inspect(provider)

  defp extract_citations(text) when is_binary(text) do
    ~r/https?:\/\/[^\s<>()\]]+/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&Regex.replace(~r/[\]\).,;:]+$/, &1, ""))
    |> Enum.uniq()
  end

  defp extract_citations(_text), do: []

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
