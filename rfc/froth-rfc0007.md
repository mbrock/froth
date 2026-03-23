# FROTH-RFC-0007: Triangulated Web Search via Multi-Provider Fan-Out

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-23
Related: FROTH-RFC-0002 (Native Multimodal LLM Layer)

## Problem

No single LLM provider has complete or unbiased web search.

Grok has x_search (native access to X's index) and web_search.
OpenAI has browsing and search grounding. Gemini has Google Search
grounding with inline citations. Anthropic has no native web search
at all. Each provider's search has a different index, different
freshness window, different political bias in result ranking, and
different hallucination profile when results are sparse.

An agent with access to one provider's search sees the web through
one eye. An agent with simultaneous access to three providers' search
sees the web through three eyes. The value is not redundancy. It is
triangulation. When three independent indexes agree, the fact is
probably a fact. When they disagree, the disagreement is the most
important part of the answer.

Today Charlie has no web search at all. Lennart has x_search and
web_search via Grok's native tools. The xpost analyzer now uses
grok_search. But none of these can cross-reference. None of them
can say "Grok says X, Gemini says Y, and GPT says Z." The
triangulation is manual — a human posts a link, Lennart searches
it, Charlie comments on the search, and the human does the
cross-referencing in their head.

## Proposal

A single tool — `web_search` — available to any Froth agent, that
fans out a search query to multiple LLM providers simultaneously,
collects their responses, and returns a collated result.

## Architecture

### The Fan-Out

```
web_search("Lindsey Graham Kharg Island Iwo Jima")
    |
    +---> Grok 4.20     (x_search + web_search)  ---> response_grok
    +---> GPT 5.4       (browsing + search)       ---> response_openai
    +---> Gemini 3.1 Pro (Google Search grounding) ---> response_gemini
    |
    v
  collation
    |
    v
  structured result returned to calling agent
```

All three calls happen concurrently via `Task.async_stream` or
equivalent. The wall-clock cost is the slowest provider, not the
sum. Typical: 2-5 seconds.

### The Query

Each provider receives the same prompt:

    Search the web for: {query}

    Return:
    1. Direct factual findings with source URLs
    2. Dates and timestamps where available
    3. Explicit uncertainty markers where results are thin
    4. If this is about a social media post, include the
       full text of the post

The prompt is adapted per provider to use their native search
mechanism:

- **Grok**: Uses the Responses API with `x_search` and
  `web_search` tools enabled. The model decides which to invoke.
- **OpenAI**: Uses the Responses API with `web_search_preview`
  tool enabled.
- **Gemini**: Uses `google_search_retrieval` grounding with
  dynamic retrieval threshold 0.3 (aggressive grounding).

### The Collation

The three responses are passed to a collation step — a single
LLM call (any provider, default Anthropic since it has no search
bias to launder) with the following prompt:

    You received three independent web search results for
    the query: {query}

    Source A (Grok/xAI): {response_grok}
    Source B (GPT/OpenAI): {response_openai}
    Source C (Gemini/Google): {response_gemini}

    Synthesize a single answer:
    - Facts confirmed by 2+ sources: state as confirmed
    - Facts from only one source: state with attribution
    - Contradictions between sources: state the contradiction
    - Source URLs: deduplicate and list
    - If any source found nothing: note the gap

    Be concise. The caller is an agent, not a human.

The collation output is the tool result returned to the calling
agent.

### Module Structure

```elixir
defmodule Froth.Search do
  @moduledoc """
  Triangulated web search via multi-provider fan-out.

  Sends the same query to Grok, OpenAI, and Gemini simultaneously,
  then collates results via a fourth LLM call.
  """

  @providers [
    {Froth.Search.Grok,   "grok-4-1-fast-reasoning"},
    {Froth.Search.OpenAI, "gpt-5.4"},
    {Froth.Search.Gemini, "gemini-3.1-pro"}
  ]

  def search(query, opts \\ []) do
    timeout = opts[:timeout] || 15_000

    results =
      @providers
      |> Task.async_stream(
        fn {mod, model} -> mod.search(query, model: model) end,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:timeout, "provider timed out"}
      end)

    collate(query, results, opts)
  end

  defp collate(query, results, opts) do
    # Fourth call: Anthropic collates
    Froth.Anthropic.chat(collation_prompt(query, results),
      model: opts[:collation_model] || "claude-sonnet-4-20250514"
    )
  end
end
```

Each provider module implements one function:

```elixir
defmodule Froth.Search.Grok do
  def search(query, opts) do
    Froth.Analyzer.API.grok_search(
      "Search the web for: #{query}\n\nReturn factual findings...",
      model: opts[:model]
    )
  end
end

defmodule Froth.Search.OpenAI do
  def search(query, opts) do
    # OpenAI Responses API with web_search_preview
    Froth.OpenAI.responses(
      "Search the web for: #{query}\n\nReturn factual findings...",
      model: opts[:model],
      tools: [%{type: "web_search_preview"}]
    )
  end
end

defmodule Froth.Search.Gemini do
  def search(query, opts) do
    # Gemini with google_search_retrieval grounding
    Froth.Gemini.generate(
      "Search the web for: #{query}\n\nReturn factual findings...",
      model: opts[:model],
      tools: [%{google_search_retrieval: %{
        dynamic_retrieval_config: %{
          mode: "MODE_DYNAMIC",
          dynamic_threshold: 0.3
        }
      }}]
    )
  end
end
```

### Agent Tool Definition

Exposed to agents as a single tool:

```json
{
  "name": "web_search",
  "description": "Search the web via three independent providers simultaneously. Returns triangulated results with source attribution and confidence markers.",
  "parameters": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The search query. Be specific."
      }
    },
    "required": ["query"]
  }
}
```

The agent does not choose which providers to query. The agent does
not see the individual provider responses. The agent sees one
collated answer. The triangulation is infrastructure, not interface.

## Relation to RFC-0002

RFC-0002 proposes a native multimodal LLM layer where each provider
speaks its own API through adapters beneath a shared semantic core.
This RFC depends on that architecture: `Froth.Search.Grok`,
`Froth.Search.OpenAI`, and `Froth.Search.Gemini` each need native
provider access to invoke vendor-specific search tools that do not
exist in compatibility-mode endpoints.

Specifically:

- Grok's `x_search` is only available through the Responses API.
- OpenAI's `web_search_preview` is only available through the
  Responses API.
- Gemini's `google_search_retrieval` is only available through the
  native Gemini API.

None of these exist in OpenAI-compatible chat completion endpoints.
The search RFC is the first consumer that makes RFC-0002's native
provider layer load-bearing rather than aesthetic.

## Cost Model

Each search invocation costs:

- 3 provider calls (one per search engine): ~$0.01-0.05 each
  depending on model and response length
- 1 collation call (Sonnet): ~$0.005
- Total: ~$0.02-0.16 per search

This is cheap enough to be a default tool on every agent. The
expensive part is not the search. The expensive part is the agent
cycle that calls the search, which already costs $0.50-2.00 in
context tokens. Adding $0.10 of search to a $1.00 cycle is a 10%
increase for a qualitative transformation in factual grounding.

## Failure Modes

1. **One provider times out**: Collation proceeds with two sources.
   The result notes which provider failed.
2. **Two providers time out**: Collation proceeds with one source.
   The result is explicitly marked as single-source, unverified.
3. **All providers time out**: Tool returns an error. The agent
   can retry or proceed without search.
4. **Providers disagree**: This is a feature, not a failure. The
   collation step presents the disagreement explicitly. The calling
   agent decides what to do with contradictory information.
5. **Provider hallucinates despite search**: Cross-referencing
   reduces this. If Grok hallucinates a fact that neither GPT nor
   Gemini found, the collation step flags it as single-source.
   The hallucination rate of the collated output is the product of
   the individual hallucination rates, not the sum. Three 5%
   hallucination rates produce a 0.0125% collated hallucination
   rate for facts that require two-source confirmation.

## Migration Path

1. Build `Froth.Search` with the three provider modules.
2. Wire it as a tool in `Froth.Agent.Config` under the name
   `web_search`.
3. Add it to Charlie's tool list. Charlie gets web search.
4. Add it to any agent's tool list as needed.
5. Lennart keeps his native Grok x_search for speed — the
   triangulated search is for situations where accuracy matters
   more than latency.

## What This Enables

- Charlie can fact-check his own claims in real time.
- Any agent can answer "what happened today" with citations.
- The xpost analyzer could use triangulated search instead of
  single-provider Grok for high-stakes posts.
- The hourly podcast can include verified news summaries.
- The family stops depending on one provider's view of reality.

The tool is a prism. One beam of light goes in. Three beams come
out. The colors that appear in all three beams are white. The
colors that appear in only one beam are the beam's opinion. The
difference between white and opinion is the entire value
proposition of the tool.
