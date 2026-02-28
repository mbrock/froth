defmodule Froth.Anthropic do
  @moduledoc false

  alias Froth.Anthropic.SSE
  alias Froth.Telemetry.Span

  @api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @default_max_tokens 16_384

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
  @type api_message :: map()

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
      body = build_request_body(config, api_messages)

      meta = %{
        mode: :stream_single,
        model: config.model,
        message_count: length(api_messages),
        tool_count: length(config.tools)
      }

      Span.span([:froth, :anthropic, :request], parent_id, meta, fn span_id ->
        case finch_stream_sse_events(@api_url, config.headers, body, on_event, span_id) do
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

  defp base_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"anthropic-beta", "context-1m-2025-08-07"}
    ]
  end

  # -- Config --

  defp build_config(overrides) do
    cfg = Application.get_env(:froth, __MODULE__, [])

    api_key =
      Keyword.get(overrides, :api_key) ||
        active_api_key() ||
        Keyword.get(cfg, :api_key)

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

      {:ok,
       %{
         api_key: api_key,
         model: model,
         system: system,
         output_config: output_config,
         thinking: thinking,
         max_tokens: max_tokens,
         tools: tools,
         headers: base_headers(api_key) ++ [{"accept", "text/event-stream"}]
       }}
    end
  end

  # -- Request body --

  defp build_request_body(config, api_messages) do
    %{
      "model" => config.model,
      "max_tokens" => config.max_tokens,
      "messages" => api_messages,
      "stream" => true
    }
    |> maybe_put_system(config.system)
    |> maybe_put_thinking(config.thinking)
    |> maybe_put_output_config(config.output_config)
    |> maybe_put_tools(config.tools)
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

  # -- Helpers --

  defp maybe_put_system(body, system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: body, else: Map.put(body, "system", system)
  end

  defp maybe_put_thinking(body, thinking) when is_map(thinking), do: Map.put(body, "thinking", thinking)
  defp maybe_put_thinking(body, _thinking), do: body

  defp maybe_put_output_config(body, output_config) when is_map(output_config), do: Map.put(body, "output_config", output_config)
  defp maybe_put_output_config(body, _output_config), do: body

  defp merge_effort_into_output_config(output_config, effort) when is_binary(effort) do
    (output_config || %{}) |> Map.put("effort", effort)
  end

  defp merge_effort_into_output_config(output_config, _effort), do: output_config

  defp maybe_put_tools(body, tools) when is_list(tools) and tools != [], do: Map.put(body, "tools", tools)
  defp maybe_put_tools(body, _tools), do: body

  defp normalize_max_tokens(max_tokens, _default) when is_integer(max_tokens) and max_tokens > 0, do: max_tokens

  defp normalize_max_tokens(max_tokens, default) when is_binary(max_tokens) do
    case Integer.parse(max_tokens) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp normalize_max_tokens(_max_tokens, default), do: default

  defp default_max_tokens(thinking_budget) when is_integer(thinking_budget), do: max(@default_max_tokens, thinking_budget + 1024)
  defp default_max_tokens(_), do: @default_max_tokens

  defp thinking_budget(%{"type" => "enabled", "budget_tokens" => budget}) when is_integer(budget), do: budget
  defp thinking_budget(_), do: nil

  defp ensure_max_tokens_above_thinking(max_tokens, thinking_budget) when is_integer(max_tokens) and is_integer(thinking_budget) do
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
    case Froth.Repo.query(
           "SELECT key FROM api_keys WHERE provider = 'anthropic' AND active = true LIMIT 1"
         ) do
      {:ok, %{rows: [[key]]}} -> key
      _ -> nil
    end
  end

  # -- HTTP / SSE --

  defp finch_stream_sse_events(url, headers, body, on_event, parent_id) do
    wrapped_on_event = wrap_on_event_with_telemetry(on_event, parent_id)

    case Application.get_env(:froth, :sse_stream_fun) do
      fun when is_function(fun, 4) ->
        fun.(url, headers, body, wrapped_on_event)

      _ ->
        do_finch_stream_sse_events(url, headers, body, wrapped_on_event, parent_id)
    end
  end

  defp do_finch_stream_sse_events(url, headers, body, on_event, parent_id) do
    all_headers = headers ++ [{"content-type", "application/json"}]
    encoded_body = Jason.encode!(body)

    http_meta = %{method: :post, url: url, headers: all_headers, body: body, stream: true}

    Span.span([:froth, :http, :request], parent_id, http_meta, fn _span_id ->
      req = Finch.build(:post, url, all_headers, encoded_body)
      state = SSE.initial_state()

      fun = fn
        {:status, status}, st ->
          {:cont, %{st | status: status}}

        {:headers, resp_headers}, st ->
          {:cont, Map.put(st, :response_headers, resp_headers)}

        {:data, chunk}, %{status: 200} = st when is_binary(chunk) ->
          {st, events, done?} = SSE.consume_events(st, chunk)
          Enum.each(events, on_event)
          if done?, do: {:halt, st}, else: {:cont, st}

        {:data, chunk}, st when is_binary(chunk) ->
          {:cont, %{st | err_buf: st.err_buf <> chunk}}
      end

      case Finch.stream_while(req, Froth.Finch, state, fun, receive_timeout: 60_000) do
        {:ok, %{status: 200} = st} ->
          result =
            {:ok,
             %{
               text: st.text,
               content: SSE.blocks_to_content(st.blocks),
               stop_reason: st.stop_reason,
               usage: st.usage,
               model: st.model,
               message_id: st.message_id
             }}

          {result, %{status: 200, response_headers: Map.get(st, :response_headers)}}

        {:ok, %{status: status, err_buf: err_body} = st} when is_integer(status) ->
          decoded =
            case Jason.decode(err_body) do
              {:ok, json} -> json
              _ -> err_body
            end

          result = {:error, {:http_error, status, decoded}}
          {result, %{status: status, response_headers: Map.get(st, :response_headers), response_body: decoded}}

        {:error, err} ->
          result = {:error, {:finch_error, err}}
          {result, %{error: err}}
      end
    end)
  end
end
