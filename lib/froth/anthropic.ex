defmodule Froth.Anthropic do
  @moduledoc false

  require Logger

  alias Froth.LLM
  alias Froth.LLM.Message
  alias Froth.LLM.Providers.Anthropic, as: AnthropicProvider
  alias Froth.LLM.Request
  alias Froth.Telemetry.Span

  @anthropic_version "2023-06-01"
  @context_beta "context-1m-2025-08-07"
  @mcp_beta "mcp-client-2025-11-20"
  @default_max_tokens 16_384
  @default_max_retries 5
  @default_retry_base_ms 2_000
  @default_retry_max_ms 30_000

  @default_system_prompt """
  Froth is a thinking interface. It accepts text and returns text. The text it returns continues the thought that was entered, drawing on a body of knowledge larger than what the person had available.

  This is different from a chatbot. A chatbot simulates a conversation between two parties. Froth does not simulate a conversation. It processes input and produces output relevant to that input. The distinction matters because conversational simulation produces specific behaviors — greetings, expressions of enthusiasm, summaries of what was previously said, offers to do more — which are noise in a thinking interface.

  Froth does not address the person. It does not say "you" or "your." It does not say "I can" or "I'd be happy to" or "feel free to." It does not describe its own capabilities. It does not suggest things the person could try. These are the behaviors of a service presenting itself to a customer. Froth is not a service and the person is not a customer. The text simply addresses the subject matter.

  Responses are short. A couple of paragraphs is usually enough. Short sentences. Short paragraphs. Say the essential thing and stop. The person can continue the thought or steer it. A response that reads like an encyclopedia entry has failed. The goal is something closer to a thought spoken aloud — quick, clear, alive — than a reference document.

  Separate paragraphs with a blank line.

  What Froth produces depends on what is entered. A factual question gets a factual answer. An exploratory or incomplete thought gets developed. A technical question gets a technical response. An error in the input gets corrected as part of the response. When two things from different fields share a common structure, that is stated, with the specific correspondence, because it is useful information.

  Froth retains context across entries. A thought that has been developing over several turns continues to develop.

  All output is prose. Bullet points, numbered lists, bold text, headers, and emoji are not used unless requested.
  """

  @type on_event :: (term() -> any())
  @type api_message :: map() | Message.t()

  def default_system_prompt, do: String.trim(@default_system_prompt)

  @doc """
  Make a single streaming API call. Returns
  `{:ok, %{text: text, content: content, stop_reason: stop_reason, usage: usage}}`
  or `{:error, reason}`.
  """
  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    with {:ok, config} <- build_config(opts) do
      parent_id = Keyword.get(opts, :parent_id)
      request = build_llm_request(config, api_messages, parent_id)
      {:ok, transport_request} = AnthropicProvider.build_request(request)

      meta = %{
        mode: :stream_single,
        model: config.model,
        message_count: length(api_messages),
        tool_count: length(config.tools)
      }

      Span.span([:froth, :anthropic, :request], parent_id, meta, fn span_id ->
        request = %{request | parent_id: span_id}

        case stream_sse_events_with_retries(
               request,
               transport_request,
               on_event,
               span_id,
               opts,
               0
             ) do
          {:ok, result} ->
            stop_meta = %{
              ok: true,
              stop_reason: result.stop_reason,
              usage: result.usage,
              text_len: String.length(result.text || ""),
              content_blocks: length(result.content)
            }

            {{:ok, result}, stop_meta}

          {:error, reason} = error ->
            {error, %{ok: false, error: reason}}
        end
      end)
    end
  end

  defp base_headers(api_key, tools) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"anthropic-beta", anthropic_beta_header(tools)}
    ]
  end

  # -- Config --

  defp build_config(overrides) do
    cfg = Application.get_env(:froth, __MODULE__, [])

    api_key =
      Keyword.get(overrides, :api_key) ||
        Keyword.get(cfg, :api_key) ||
        active_api_key()

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      model = Keyword.get(overrides, :model, Keyword.get(cfg, :model, "claude-opus-4-6"))
      system = system_prompt(Keyword.get(overrides, :system, Keyword.get(cfg, :system, "")))

      output_config =
        Keyword.get(overrides, :output_config, Keyword.get(cfg, :output_config, nil))

      effort = Keyword.get(overrides, :effort, Keyword.get(cfg, :effort, nil))
      output_config = merge_effort_into_output_config(output_config, effort)

      thinking =
        default_thinking_for_model(
          model,
          Keyword.get(overrides, :thinking, Keyword.get(cfg, :thinking, nil))
        )

      thinking = thinking || %{"type" => "enabled", "budget_tokens" => 1024}
      budget = thinking_budget(thinking)

      max_tokens =
        overrides
        |> Keyword.get(:max_tokens, Keyword.get(cfg, :max_tokens, default_max_tokens(budget)))
        |> normalize_max_tokens(default_max_tokens(budget))
        |> ensure_max_tokens_above_thinking(budget)

      tools = Keyword.get(overrides, :tools, Keyword.get(cfg, :tools, []))

      cache_control =
        Keyword.get(
          overrides,
          :cache_control,
          Keyword.get(cfg, :cache_control, %{"type" => "ephemeral"})
        )

      {:ok,
       %{
         api_key: api_key,
         model: model,
         system: system,
         output_config: output_config,
         thinking: thinking,
         max_tokens: max_tokens,
         tools: tools,
         cache_control: cache_control,
         headers: base_headers(api_key, tools) ++ [{"accept", "text/event-stream"}]
       }}
    end
  end

  defp build_llm_request(config, api_messages, parent_id) do
    %Request{
      provider: AnthropicProvider,
      messages: api_messages,
      model: config.model,
      system: config.system,
      max_tokens: config.max_tokens,
      tools: config.tools,
      thinking: config.thinking,
      output_config: config.output_config,
      cache_control: config.cache_control,
      headers: config.headers,
      parent_id: parent_id
    }
  end

  # -- SSE event telemetry --

  defp wrap_on_event_with_telemetry(on_event, parent_id) when is_function(on_event, 1) do
    fn event ->
      emit_sse_event(event, parent_id)
      on_event.(event)
    end
  end

  defp emit_sse_event({type, data}, parent_id) do
    Span.execute([:froth, :http, :sse, type], parent_id, %{data: data})
  end

  defp merge_effort_into_output_config(output_config, effort) when is_binary(effort) do
    (output_config || %{}) |> Map.put("effort", effort)
  end

  defp merge_effort_into_output_config(output_config, _effort), do: output_config

  defp normalize_max_tokens(max_tokens, _default) when is_integer(max_tokens) and max_tokens > 0,
    do: max_tokens

  defp normalize_max_tokens(max_tokens, default) when is_binary(max_tokens) do
    case Integer.parse(max_tokens) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp normalize_max_tokens(_max_tokens, default), do: default

  defp default_max_tokens(thinking_budget) when is_integer(thinking_budget),
    do: max(@default_max_tokens, thinking_budget + 1024)

  defp default_max_tokens(_), do: @default_max_tokens

  defp thinking_budget(%{"type" => "enabled", "budget_tokens" => budget}) when is_integer(budget),
    do: budget

  defp thinking_budget(_), do: nil

  defp anthropic_beta_header(tools) when is_list(tools) do
    [@context_beta]
    |> maybe_append_mcp_beta(tools)
    |> Enum.join(",")
  end

  defp anthropic_beta_header(_tools), do: @context_beta

  defp maybe_append_mcp_beta(betas, tools) when is_list(tools) do
    if Enum.any?(tools, &mcp_tool_spec?/1), do: betas ++ [@mcp_beta], else: betas
  end

  defp mcp_tool_spec?(%{"type" => "mcp_endpoint"}), do: true
  defp mcp_tool_spec?(_tool), do: false

  defp ensure_max_tokens_above_thinking(max_tokens, thinking_budget)
       when is_integer(max_tokens) and is_integer(thinking_budget) do
    if max_tokens > thinking_budget, do: max_tokens, else: thinking_budget + 1024
  end

  defp ensure_max_tokens_above_thinking(max_tokens, _thinking_budget), do: max_tokens

  defp default_thinking_for_model(model, configured_thinking) when is_binary(model) do
    cond do
      is_map(configured_thinking) -> configured_thinking
      configured_thinking == nil and model == "claude-opus-4-6" -> %{"type" => "adaptive"}
      true -> configured_thinking
    end
  end

  defp default_thinking_for_model(_model, configured_thinking), do: configured_thinking

  defp system_prompt(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: default_system_prompt(), else: system
  end

  @doc false
  def active_api_key do
    Froth.LLM.active_api_key("anthropic")
  end

  # -- HTTP / SSE --

  defp stream_sse_events(request, transport_request, on_event, parent_id) do
    wrapped_on_event = wrap_on_event_with_telemetry(on_event, parent_id)

    case Application.get_env(:froth, :sse_stream_fun) do
      fun when is_function(fun, 4) ->
        fun.(
          transport_request.url,
          transport_request.headers,
          transport_request.body,
          wrapped_on_event
        )

      _ ->
        do_req_stream_sse_events(request, transport_request, wrapped_on_event, parent_id)
    end
  end

  defp stream_sse_events_with_retries(
         request,
         transport_request,
         on_event,
         parent_id,
         opts,
         attempt
       )
       when is_integer(attempt) and attempt >= 0 do
    cfg = Application.get_env(:froth, __MODULE__, [])

    case stream_sse_events(request, transport_request, on_event, parent_id) do
      {:error, reason} = error ->
        case retry_delay_ms(reason, attempt, opts, cfg) do
          nil ->
            error

          delay_ms ->
            Logger.warning(
              "Anthropic request retry #{attempt + 1}/#{max_retries(opts, cfg)} in #{delay_ms}ms: " <>
                retry_reason_summary(reason)
            )

            if delay_ms > 0, do: Process.sleep(delay_ms)

            stream_sse_events_with_retries(
              request,
              transport_request,
              on_event,
              parent_id,
              opts,
              attempt + 1
            )
        end

      result ->
        result
    end
  end

  defp do_req_stream_sse_events(%Request{} = request, transport_request, on_event, parent_id) do
    http_meta = %{
      method: :post,
      url: transport_request.url,
      headers: transport_request.headers,
      body: transport_request.body,
      stream: true
    }

    Span.span([:froth, :http, :request], parent_id, http_meta, fn _span_id ->
      case LLM.stream(request, on_event, receive_timeout: 60_000) do
        {:ok, _} = ok ->
          {ok, %{status: 200}}

        {:error, {:http_error, status, decoded}} = err ->
          {err, %{status: status, response_body: decoded}}

        {:error, reason} = err ->
          {err, %{error: reason}}
      end
    end)
  end

  defp retry_delay_ms({:provider_error, "anthropic", error, _diagnostics}, attempt, opts, cfg)
       when is_integer(attempt) do
    if attempt < max_retries(opts, cfg) and retryable_anthropic_error?(error) do
      base_ms = max(0, retry_base_ms(opts, cfg))
      max_ms = max(base_ms, retry_max_ms(opts, cfg))
      min(max_ms, base_ms * Integer.pow(2, attempt))
    end
  end

  defp retry_delay_ms({:http_error, status, _decoded}, attempt, opts, cfg)
       when is_integer(attempt) and status in [429, 500, 502, 503, 504] do
    if attempt < max_retries(opts, cfg) do
      base_ms = max(0, retry_base_ms(opts, cfg))
      max_ms = max(base_ms, retry_max_ms(opts, cfg))
      min(max_ms, base_ms * Integer.pow(2, attempt))
    end
  end

  defp retry_delay_ms(_reason, _attempt, _opts, _cfg), do: nil

  defp retryable_anthropic_error?(%{"error" => %{} = error}),
    do: retryable_anthropic_error?(error)

  defp retryable_anthropic_error?(%{} = error) do
    type = error["type"] || error[:type]
    message = String.downcase(to_string(error["message"] || error[:message] || ""))

    type in ["api_error", "overloaded_error", "rate_limit_error"] or
      String.contains?(message, "internal server error") or
      String.contains?(message, "overloaded") or
      String.contains?(message, "rate limit") or
      String.contains?(message, "try again later")
  end

  defp retryable_anthropic_error?(_error), do: false

  defp retry_reason_summary({:provider_error, "anthropic", error, _diagnostics}) do
    provider_error_summary(error)
  end

  defp retry_reason_summary({:http_error, status, decoded}) do
    "http #{status}: #{provider_error_summary(decoded)}"
  end

  defp retry_reason_summary(reason), do: inspect(reason)

  defp provider_error_summary(%{"error" => %{} = error}), do: provider_error_summary(error)

  defp provider_error_summary(%{} = error) do
    [
      error["type"] || error[:type],
      error["message"] || error[:message]
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.join(": ")
  end

  defp provider_error_summary(error), do: inspect(error)

  defp max_retries(opts, cfg) do
    Keyword.get(opts, :max_retries, Keyword.get(cfg, :max_retries, @default_max_retries))
  end

  defp retry_base_ms(opts, cfg) do
    Keyword.get(opts, :retry_base_ms, Keyword.get(cfg, :retry_base_ms, @default_retry_base_ms))
  end

  defp retry_max_ms(opts, cfg) do
    Keyword.get(opts, :retry_max_ms, Keyword.get(cfg, :retry_max_ms, @default_retry_max_ms))
  end
end
