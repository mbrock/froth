defmodule Froth.Anthropic do
  @moduledoc false

  require Logger

  alias Froth.Anthropic.SSE

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

  @spec reply([chat_message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def reply(history, opts \\ []) when is_list(history) do
    with {:ok, config} <- build_config(opts) do
      with_telemetry(config, history, fn ->
        body = build_request_body(config, Enum.map(history, &to_api_message/1))
        finch_post_json(@api_url, config.api_key, body)
      end)
    end
  end

  @doc """
  Make a single streaming API call without tool-looping.
  Returns
  `{:ok, %{text: text, content: content, stop_reason: stop_reason, usage: usage}}`
  or `{:error, reason}`.
  """
  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    with {:ok, config} <- build_config(opts) do
      body = build_request_body(config, api_messages, stream: true, tools: true)
      request_id = new_request_id()

      log_anthropic_stream_start(:stream_single, request_id, body, %{
        message_count: length(api_messages)
      })

      case finch_stream_sse_events(@api_url, config.headers, body, on_event,
             request_id: request_id,
             mode: :stream_single
           ) do
        {:ok, result} ->
          log_anthropic_stream_finish(:stream_single, request_id, result)
          {:ok, result}

        {:error, reason} = error ->
          log_anthropic_stream_error(:stream_single, request_id, reason)
          error
      end
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
      api_messages = Enum.map(history, &ensure_api_message/1)
      request_id = new_request_id()

      on_persist.(api_messages)

      log_anthropic_stream_start(:tool_loop, request_id, %{
        "model" => config.model,
        "messages" => api_messages,
        "thinking" => config.thinking,
        "tools" => config.tools
      })

      result =
        with_telemetry(
          config,
          history,
          fn ->
            tool_loop(config, api_messages, on_event, on_persist, on_tool, "", 0, %{}, request_id)
          end,
          stream: true
        )

      case result do
        {:ok, %{text: text, api_messages: api_messages, usage: usage}} ->
          Logger.info(
            event: :anthropic_tool_loop_complete,
            request_id: request_id,
            text_len: String.length(text),
            api_messages: length(api_messages),
            usage: inspect(usage)
          )

          result

        {:ok, %{text: text, api_messages: api_messages}} ->
          Logger.info(
            event: :anthropic_tool_loop_complete,
            request_id: request_id,
            text_len: String.length(text),
            api_messages: length(api_messages)
          )

          result

        {:error, reason} = error ->
          log_anthropic_stream_error(:tool_loop, request_id, reason)
          error
      end
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

  defp tool_loop(
         config,
         api_messages,
         on_event,
         on_persist,
         on_tool,
         acc_text,
         iter,
         acc_usage,
         request_id
       ) do
    turn = iter + 1
    body = build_request_body(config, api_messages, stream: true, tools: true)
    log_anthropic_turn_start(request_id, turn, body)

    with {:ok, %{text: text, content: content, stop_reason: stop_reason} = stream_reply} <-
           finch_stream_sse_events(@api_url, config.headers, body, on_event,
             request_id: request_id,
             mode: :tool_loop,
             turn: turn
           ) do
      usage = Map.get(stream_reply, :usage, %{})
      acc_usage = merge_usage_totals(acc_usage, usage)
      acc_text = join_text(acc_text, text)
      tool_uses = Enum.filter(content, &match?(%{"type" => "tool_use"}, &1))
      log_anthropic_turn_result(request_id, turn, stop_reason, text, usage, length(tool_uses))

      if stop_reason == "tool_use" and tool_uses != [] do
        tool_results = run_tools(tool_uses, on_event, on_tool, request_id, turn)

        api_messages =
          api_messages ++
            [
              %{"role" => "assistant", "content" => content},
              %{"role" => "user", "content" => tool_results}
            ]

        on_persist.(api_messages)

        tool_loop(
          config,
          api_messages,
          on_event,
          on_persist,
          on_tool,
          acc_text,
          turn,
          acc_usage,
          request_id
        )
      else
        final_messages = api_messages ++ [%{"role" => "assistant", "content" => content}]
        on_persist.(final_messages)
        {:ok, %{text: String.trim(acc_text), api_messages: final_messages, usage: acc_usage}}
      end
    end
  end

  defp run_tools(tool_uses, on_event, on_tool, request_id, turn) do
    Enum.map(tool_uses, fn %{"id" => id, "name" => name, "input" => input} ->
      Logger.info(
        event: :anthropic_tool_exec_start,
        request_id: request_id,
        turn: turn,
        tool_use_id: id,
        tool_name: name,
        input_preview: preview(input)
      )

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

      Logger.info(
        event: :anthropic_tool_exec_finish,
        request_id: request_id,
        turn: turn,
        tool_use_id: id,
        tool_name: name,
        is_error: is_error,
        result_preview: preview(content)
      )

      %{
        "type" => "tool_result",
        "tool_use_id" => id,
        "is_error" => is_error,
        "content" => content
      }
    end)
  end

  defp join_text("", text), do: text

  defp join_text(acc, text) do
    String.trim_trailing(acc) <> "\n\n" <> String.trim_leading(text)
  end

  defp new_request_id do
    "anth-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp log_anthropic_stream_start(mode, request_id, body, extra \\ %{}) when is_map(body) do
    system = Map.get(body, "system", "")

    Logger.info(
      event: :anthropic_stream_start,
      mode: mode,
      request_id: request_id,
      model: Map.get(body, "model"),
      message_count: length(Map.get(body, "messages", [])),
      tool_count: length(Map.get(body, "tools", [])),
      stream: Map.get(body, "stream", false),
      thinking: inspect(Map.get(body, "thinking")),
      system_len: String.length(system),
      extra: inspect(extra)
    )

    Froth.broadcast(
      "anthropic:#{request_id}",
      {mode, :stream_start, %{model: Map.get(body, "model")}}
    )
  end

  defp log_anthropic_stream_finish(mode, request_id, result) when is_map(result) do
    usage = Map.get(result, :usage, %{})

    Logger.info(
      event: :anthropic_stream_finish,
      mode: mode,
      request_id: request_id,
      stop_reason: Map.get(result, :stop_reason),
      text_len: Map.get(result, :text, "") |> to_string() |> String.length(),
      content_blocks: length(Map.get(result, :content, [])),
      usage: inspect(usage)
    )

    Froth.broadcast(
      "anthropic:#{request_id}",
      {mode, :stream_finish, %{stop_reason: Map.get(result, :stop_reason), usage: usage}}
    )
  end

  defp log_anthropic_stream_error(mode, request_id, reason) do
    Logger.error(
      event: :anthropic_stream_error,
      mode: mode,
      request_id: request_id,
      reason: inspect(reason)
    )

    Froth.broadcast("anthropic:#{request_id}", {mode, :stream_error, reason})
  end

  defp log_anthropic_turn_start(request_id, turn, body) do
    Logger.info(
      event: :anthropic_tool_loop_turn_start,
      request_id: request_id,
      turn: turn,
      message_count: length(Map.get(body, "messages", [])),
      tool_count: length(Map.get(body, "tools", []))
    )
  end

  defp log_anthropic_turn_result(request_id, turn, stop_reason, text, usage, tool_use_count) do
    Logger.info(
      event: :anthropic_tool_loop_turn_result,
      request_id: request_id,
      turn: turn,
      stop_reason: stop_reason,
      text_len: String.length(to_string(text || "")),
      tool_use_count: tool_use_count,
      usage: inspect(usage)
    )
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

  defp preview(value) when is_binary(value), do: String.slice(value, 0, 250)

  defp preview(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> String.slice(encoded, 0, 250)
      _ -> inspect(value, limit: 100, printable_limit: 250)
    end
  end

  defp wrap_on_event_with_logging(on_event, opts) when is_function(on_event, 1) do
    fn event ->
      log_stream_event(event, opts)
      Froth.broadcast("anthropic:#{opts[:request_id]}", {opts[:mode], event})
      on_event.(event)
    end
  end

  defp log_stream_event({:thinking_start, %{"index" => idx}}, opts) do
    Logger.info(base_log_metadata(opts) ++ [event: :anthropic_thinking_start, index: idx])
  end

  defp log_stream_event({:thinking_stop, %{"index" => idx, "thinking" => thinking}}, opts) do
    Logger.info(
      base_log_metadata(opts) ++
        [event: :anthropic_thinking_stop, index: idx, thinking_len: String.length(thinking || "")]
    )
  end

  defp log_stream_event({:tool_use_start, %{"id" => id, "name" => name, "input" => input}}, opts) do
    Logger.info(
      base_log_metadata(opts) ++
        [
          event: :anthropic_tool_use_start,
          tool_use_id: id,
          tool_name: name,
          input_preview: preview(input)
        ]
    )
  end

  defp log_stream_event({:tool_use_stop, %{"id" => id, "name" => name, "input" => input}}, opts) do
    Logger.info(
      base_log_metadata(opts) ++
        [
          event: :anthropic_tool_use_stop,
          tool_use_id: id,
          tool_name: name,
          input_preview: preview(input)
        ]
    )
  end

  defp log_stream_event(
         {:tool_result,
          %{"tool_use_id" => id, "name" => name, "is_error" => is_error, "content" => content}},
         opts
       ) do
    Logger.info(
      base_log_metadata(opts) ++
        [
          event: :anthropic_tool_result,
          tool_use_id: id,
          tool_name: name,
          is_error: is_error,
          result_preview: preview(content)
        ]
    )
  end

  defp log_stream_event(
         {:usage, %{"phase" => phase, "usage" => usage, "accumulated_usage" => accumulated}},
         opts
       ) do
    Logger.info(
      base_log_metadata(opts) ++
        [
          event: :anthropic_usage,
          phase: phase,
          usage: inspect(usage),
          accumulated_usage: inspect(accumulated)
        ]
    )
  end

  defp log_stream_event({:message_start, %{"id" => id, "model" => model}}, opts) do
    Logger.info(
      base_log_metadata(opts) ++ [event: :anthropic_message_start, response_id: id, model: model]
    )
  end

  defp log_stream_event({:text_delta, _}, _opts), do: :ok
  defp log_stream_event({:thinking_delta, _}, _opts), do: :ok
  defp log_stream_event({:tool_use_delta, _}, _opts), do: :ok
  defp log_stream_event(_event, _opts), do: :ok

  defp base_log_metadata(opts) do
    [request_id: opts[:request_id], mode: opts[:mode], turn: opts[:turn]]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # -- Telemetry --

  defp with_telemetry(config, history, fun, opts \\ []) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    {ok?, status} =
      case result do
        {:ok, _} -> {true, 200}
        {:error, {:http_error, s, _}} -> {false, s}
        {:error, _} -> {false, nil}
      end

    metadata = %{ok?: ok?, status: status, model: config.model, messages: length(history)}
    metadata = if opts[:stream], do: Map.put(metadata, :stream, true), else: metadata

    :telemetry.execute(
      [:froth, :anthropic, :request],
      %{duration: duration, count: 1},
      metadata
    )

    result
  end

  defp to_api_message(%{role: role, text: text}) when role in [:user, :assistant] do
    %{"role" => Atom.to_string(role), "content" => text}
  end

  # Messages already in API format pass through; legacy atom-keyed maps get converted
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
    # Claude Opus 4.6 docs recommend adaptive thinking; enabled/budget is deprecated on Opus 4.6.
    # Allow explicit config to override.
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

  defp debug_enabled?, do: System.get_env("FROTH_DEBUG_ANTHROPIC") in ["1", "true", "yes"]

  defp debug_log_request(body) when is_map(body) do
    if debug_enabled?() do
      system = Map.get(body, "system", "")

      Logger.info(
        event: :request,
        model: Map.get(body, "model"),
        stream: Map.get(body, "stream", false),
        messages: length(Map.get(body, "messages", [])),
        system: system != "",
        system_len: String.length(system)
      )
    end

    :ok
  end

  defp debug_log_response(status) when is_integer(status) do
    if debug_enabled?(), do: Logger.info(event: :response, status: status)
    :ok
  end

  defp system_prompt(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: default_system_prompt(), else: system
  end

  defp finch_post_json(url, api_key, body) do
    case finch_post_json_decoded(url, api_key, body) do
      {:ok, %{"content" => content}} ->
        {:ok, content_to_text(content)}

      {:ok, other} ->
        {:error, {:http_error, 200, other}}

      {:error, _} = err ->
        err
    end
  end

  defp finch_post_json_decoded(url, api_key, body) do
    case Application.get_env(:froth, :post_json_fun) do
      fun when is_function(fun, 3) ->
        fun.(url, api_key, body)

      _ ->
        do_finch_post_json_decoded(url, api_key, body)
    end
  end

  defp do_finch_post_json_decoded(url, api_key, body) do
    debug_log_request(body)

    headers = base_headers(api_key) ++ [{"content-type", "application/json"}]

    req = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(req, Froth.Finch, receive_timeout: 60_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        debug_log_response(200)

        case Jason.decode(resp_body) do
          {:ok, json} -> {:ok, json}
          {:error, err} -> {:error, {:decode_error, err}}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        debug_log_response(status)

        decoded =
          case Jason.decode(resp_body) do
            {:ok, json} -> json
            _ -> resp_body
          end

        {:error, {:http_error, status, decoded}}

      {:error, err} ->
        {:error, {:finch_error, err}}
    end
  end

  defp finch_stream_sse_events(url, headers, body, on_event, opts) do
    wrapped_on_event = wrap_on_event_with_logging(on_event, opts)

    case Application.get_env(:froth, :sse_stream_fun) do
      fun when is_function(fun, 4) ->
        fun.(url, headers, body, wrapped_on_event)

      _ ->
        do_finch_stream_sse_events(url, headers, body, wrapped_on_event, opts)
    end
  end

  defp do_finch_stream_sse_events(url, headers, body, on_event, opts) do
    debug_log_request(body)

    req =
      Finch.build(
        :post,
        url,
        headers ++ [{"content-type", "application/json"}],
        Jason.encode!(body)
      )

    state = SSE.initial_state()

    fun = fn
      {:status, status}, st ->
        Logger.info(
          event: :anthropic_stream_http_status,
          request_id: opts[:request_id],
          mode: opts[:mode],
          turn: opts[:turn],
          status: status
        )

        {:cont, %{st | status: status}}

      {:headers, _headers}, st ->
        {:cont, st}

      {:data, chunk}, %{status: 200} = st when is_binary(chunk) ->
        {st, events, done?} = SSE.consume_events(st, chunk)
        Enum.each(events, on_event)
        if done?, do: {:halt, st}, else: {:cont, st}

      {:data, chunk}, st when is_binary(chunk) ->
        {:cont, %{st | err_buf: st.err_buf <> chunk}}
    end

    case Finch.stream_while(req, Froth.Finch, state, fun, receive_timeout: 60_000) do
      {:ok, %{status: 200} = st} ->
        debug_log_response(200)

        {:ok,
         %{
           text: st.text,
           content: SSE.blocks_to_content(st.blocks),
           stop_reason: st.stop_reason,
           usage: st.usage,
           model: st.model,
           message_id: st.message_id
         }}

      {:ok, %{status: status, err_buf: err_body}} when is_integer(status) ->
        debug_log_response(status)

        decoded =
          case Jason.decode(err_body) do
            {:ok, json} -> json
            _ -> err_body
          end

        {:error, {:http_error, status, decoded}}

      {:error, err} ->
        {:error, {:finch_error, err}}
    end
  end
end
