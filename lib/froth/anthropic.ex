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

  @type role :: :user | :assistant
  @type chat_message :: %{role: role(), text: String.t()}

  @type on_event :: (term() -> any())
  @type api_message :: map()

  defp default_max_tokens(thinking_budget) when is_integer(thinking_budget) do
    max(@default_max_tokens, thinking_budget + 1024)
  end

  defp default_max_tokens(_), do: @default_max_tokens

  defp thinking_budget(%{"type" => "enabled", "budget_tokens" => budget}) when is_integer(budget),
    do: budget

  defp thinking_budget(_), do: nil

  defp ensure_max_tokens_above_thinking(max_tokens, thinking_budget)
       when is_integer(max_tokens) and is_integer(thinking_budget) do
    if max_tokens > thinking_budget, do: max_tokens, else: thinking_budget + 1024
  end

  defp ensure_max_tokens_above_thinking(max_tokens, _thinking_budget), do: max_tokens

  def default_system_prompt, do: String.trim(@default_system_prompt)

  # -- Public API --

  @spec reply([chat_message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def reply(history, opts \\ []) when is_list(history) do
    with {:ok, config} <- build_config(opts) do
      parent_id = Keyword.get(opts, :parent_id)

      meta = %{
        mode: :reply,
        model: config.model,
        message_count: length(history),
        tool_count: 0
      }

      Span.span([:froth, :anthropic, :request], parent_id, meta, fn span_id ->
        body = build_request_body(config, Enum.map(history, &to_api_message/1))

        case finch_post_json(@api_url, config.api_key, body, span_id) do
          {:ok, text} = result ->
            {result, %{ok: true, text_len: String.length(text)}}

          {:error, reason} = error ->
            {error, %{ok: false, error: reason}}
        end
      end)
    end
  end

  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    with {:ok, config} <- build_config(opts) do
      parent_id = Keyword.get(opts, :parent_id)
      body = build_request_body(config, api_messages, stream: true, tools: true)

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

  @spec stream_reply_with_tools([chat_message() | api_message()], on_event(), keyword()) ::
          {:ok, %{text: String.t(), api_messages: [api_message()], usage: map()}}
          | {:error, term()}
  def stream_reply_with_tools(history, on_event, opts \\ [])
      when is_list(history) and is_function(on_event, 1) do
    on_persist = Keyword.get(opts, :on_persist, fn _ -> :ok end)
    on_tool = Keyword.get(opts, :on_tool, fn _name, _input -> {:error, "no tools configured"} end)

    with {:ok, config} <- build_config(opts) do
      parent_id = Keyword.get(opts, :parent_id)
      api_messages = Enum.map(history, &ensure_api_message/1)

      on_persist.(api_messages)

      meta = %{
        mode: :tool_loop,
        model: config.model,
        message_count: length(api_messages),
        tool_count: length(config.tools)
      }

      Span.span([:froth, :anthropic, :request], parent_id, meta, fn span_id ->
        case tool_loop(config, api_messages, on_event, on_persist, on_tool, "", 0, %{}, span_id) do
          {:ok, %{text: text, api_messages: msgs, usage: usage}} = result ->
            {result, %{ok: true, text_len: String.length(text), api_message_count: length(msgs), usage: usage}}

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

  defp build_request_body(config, api_messages, opts \\ []) do
    %{
      "model" => config.model,
      "max_tokens" => config.max_tokens,
      "messages" => api_messages
    }
    |> then(fn body -> if opts[:stream], do: Map.put(body, "stream", true), else: body end)
    |> maybe_put_system(config.system)
    |> maybe_put_thinking(config.thinking)
    |> maybe_put_output_config(config.output_config)
    |> then(fn body -> if opts[:tools], do: maybe_put_tools(body, config.tools), else: body end)
  end

  # -- Tool loop --

  defp tool_loop(config, api_messages, on_event, on_persist, on_tool, acc_text, iter, acc_usage, parent_id) do
    turn = iter + 1
    body = build_request_body(config, api_messages, stream: true, tools: true)

    turn_meta = %{
      turn: turn,
      message_count: length(api_messages),
      tool_count: length(config.tools)
    }

    Span.span([:froth, :anthropic, :turn], parent_id, turn_meta, fn turn_span_id ->
      with {:ok, %{text: text, content: content, stop_reason: stop_reason} = stream_reply} <-
             finch_stream_sse_events(@api_url, config.headers, body, on_event, turn_span_id) do
        usage = Map.get(stream_reply, :usage, %{})
        acc_usage = merge_usage_totals(acc_usage, usage)
        acc_text = join_text(acc_text, text)
        tool_uses = Enum.filter(content, &match?(%{"type" => "tool_use"}, &1))

        turn_stop_meta = %{
          stop_reason: stop_reason,
          text_len: String.length(to_string(text || "")),
          tool_use_count: length(tool_uses),
          usage: usage
        }

        if stop_reason == "tool_use" and tool_uses != [] do
          tool_results = run_tools(tool_uses, on_event, on_tool, turn_span_id)

          api_messages =
            api_messages ++
              [
                %{"role" => "assistant", "content" => content},
                %{"role" => "user", "content" => tool_results}
              ]

          on_persist.(api_messages)

          result = tool_loop(config, api_messages, on_event, on_persist, on_tool, acc_text, turn, acc_usage, parent_id)
          {result, turn_stop_meta}
        else
          final_messages = api_messages ++ [%{"role" => "assistant", "content" => content}]
          on_persist.(final_messages)
          result = {:ok, %{text: String.trim(acc_text), api_messages: final_messages, usage: acc_usage}}
          {result, turn_stop_meta}
        end
      end
    end)
  end

  defp run_tools(tool_uses, on_event, on_tool, parent_id) do
    Enum.map(tool_uses, fn %{"id" => id, "name" => name, "input" => input} ->
      tool_meta = %{tool_use_id: id, tool_name: name, input: input}

      Span.span([:froth, :anthropic, :tool_exec], parent_id, tool_meta, fn _span_id ->
        {is_error, content} =
          case on_tool.(name, input) do
            {:ok, out} -> {false, out}
            {:error, msg} -> {true, msg}
          end

        on_event.(
          {:tool_result,
           %{
             "tool_use_id" => id,
             "name" => name,
             "is_error" => is_error,
             "content" => content
           }}
        )

        result = %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "is_error" => is_error,
          "content" => content
        }

        {result, %{is_error: is_error, result: content}}
      end)
    end)
  end

  defp join_text("", text), do: text

  defp join_text(acc, text) do
    String.trim_trailing(acc) <> "\n\n" <> String.trim_leading(text)
  end

  defp merge_usage_totals(acc, usage) when is_map(usage) do
    Map.merge(acc, usage, fn _key, left, right ->
      cond do
        is_map(left) and is_map(right) ->
          merge_usage_totals(left, right)

        is_integer(left) and is_integer(right) ->
          left + right

        true ->
          right
      end
    end)
  end

  defp merge_usage_totals(acc, _usage), do: acc

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

  defp to_api_message(%{role: role, text: text}) when role in [:user, :assistant] do
    %{"role" => Atom.to_string(role), "content" => text}
  end

  defp ensure_api_message(%{"role" => _, "content" => _} = msg), do: msg
  defp ensure_api_message(%{role: _, text: _} = msg), do: to_api_message(msg)

  defp maybe_put_system(body, system) when is_binary(system) do
    system = String.trim(system)

    if system == "" do
      body
    else
      Map.put(body, "system", system)
    end
  end

  defp maybe_put_thinking(body, thinking) when is_map(thinking) do
    Map.put(body, "thinking", thinking)
  end

  defp maybe_put_thinking(body, _thinking), do: body

  defp maybe_put_output_config(body, output_config) when is_map(output_config) do
    Map.put(body, "output_config", output_config)
  end

  defp maybe_put_output_config(body, _output_config), do: body

  defp merge_effort_into_output_config(output_config, effort) when is_binary(effort) do
    (output_config || %{})
    |> Map.put("effort", effort)
  end

  defp merge_effort_into_output_config(output_config, _effort), do: output_config

  defp maybe_put_tools(body, tools) when is_list(tools) and tools != [] do
    Map.put(body, "tools", tools)
  end

  defp maybe_put_tools(body, _tools), do: body

  defp normalize_max_tokens(max_tokens, _default)
       when is_integer(max_tokens) and max_tokens > 0,
       do: max_tokens

  defp normalize_max_tokens(max_tokens, default) when is_binary(max_tokens) do
    case Integer.parse(max_tokens) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp normalize_max_tokens(_max_tokens, default), do: default

  defp default_thinking_for_model(model, configured_thinking) when is_binary(model) do
    cond do
      is_map(configured_thinking) ->
        configured_thinking

      configured_thinking == nil and model == "claude-opus-4-6" ->
        %{"type" => "adaptive"}

      true ->
        configured_thinking
    end
  end

  defp default_thinking_for_model(_model, configured_thinking), do: configured_thinking

  @doc false
  def active_api_key do
    case Froth.Repo.query(
           "SELECT key FROM api_keys WHERE provider = 'anthropic' AND active = true LIMIT 1"
         ) do
      {:ok, %{rows: [[key]]}} -> key
      _ -> nil
    end
  end

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp content_to_text(text) when is_binary(text), do: text
  defp content_to_text(_), do: ""

  defp system_prompt(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: default_system_prompt(), else: system
  end

  defp finch_post_json(url, api_key, body, parent_id) do
    case finch_post_json_decoded(url, api_key, body, parent_id) do
      {:ok, %{"content" => content}} ->
        {:ok, content_to_text(content)}

      {:ok, other} ->
        {:error, {:http_error, 200, other}}

      {:error, _} = err ->
        err
    end
  end

  defp finch_post_json_decoded(url, api_key, body, parent_id) do
    case Application.get_env(:froth, :post_json_fun) do
      fun when is_function(fun, 3) ->
        fun.(url, api_key, body)

      _ ->
        do_finch_post_json_decoded(url, api_key, body, parent_id)
    end
  end

  defp do_finch_post_json_decoded(url, api_key, body, parent_id) do
    headers = base_headers(api_key) ++ [{"content-type", "application/json"}]
    encoded_body = Jason.encode!(body)

    http_meta = %{method: :post, url: url, headers: headers, body: body}

    Span.span([:froth, :http, :request], parent_id, http_meta, fn _span_id ->
      req = Finch.build(:post, url, headers, encoded_body)

      case Finch.request(req, Froth.Finch, receive_timeout: 60_000) do
        {:ok, %Finch.Response{status: 200, body: resp_body} = resp} ->
          case Jason.decode(resp_body) do
            {:ok, json} ->
              {{:ok, json}, %{status: 200, response_headers: resp.headers, response_body: json}}

            {:error, err} ->
              result = {:error, {:decode_error, err}}
              {result, %{status: 200, response_headers: resp.headers, response_body: resp_body, error: err}}
          end

        {:ok, %Finch.Response{status: status, body: resp_body} = resp} ->
          decoded =
            case Jason.decode(resp_body) do
              {:ok, json} -> json
              _ -> resp_body
            end

          result = {:error, {:http_error, status, decoded}}
          {result, %{status: status, response_headers: resp.headers, response_body: decoded}}

        {:error, err} ->
          result = {:error, {:finch_error, err}}
          {result, %{error: err}}
      end
    end)
  end

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
