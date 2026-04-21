defmodule Froth.LLM do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Froth.ApiKey
  alias Froth.LLM.{Client, Edit, Message, Request, Store}
  alias Froth.LLM.Transport.SSE
  alias Froth.Telemetry.Span

  @type on_event :: (term() -> any())
  @type on_edit :: (Edit.t() -> any())
  @type provider_ref :: atom() | String.t() | module() | nil

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

  def default_system_prompt, do: String.trim(@default_system_prompt)

  # -- Provider registry --

  @providers %{
    anthropic: %{
      key_providers: ["anthropic"],
      provider_module: Froth.LLM.Providers.Anthropic,
      endpoint: "https://api.anthropic.com/v1/messages",
      auth: :anthropic,
      config_key: Froth.Anthropic
    },
    openai: %{
      key_providers: ["openai"],
      provider_module: Froth.LLM.Providers.OpenAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      auth: :bearer,
      config_key: Froth.OpenAI
    },
    grok: %{
      key_providers: ["grok", "xai"],
      provider_module: Froth.LLM.Providers.OpenAIResponses,
      endpoint: "https://api.x.ai/v1/responses",
      auth: :bearer,
      config_key: Froth.Grok
    },
    gemini: %{
      key_providers: ["gemini", "google"],
      provider_module: Froth.LLM.Providers.GeminiInteractions,
      endpoint:
        "https://generativelanguage.googleapis.com/v1beta/interactions",
      auth: :query_key,
      config_key: Froth.Gemini
    },
    fakeai: %{
      key_providers: ["fakeai"],
      provider_module: Froth.LLM.Providers.Fake,
      endpoint: "fake://",
      auth: :none,
      config_key: nil
    }
  }

  @doc "Look up the API key for a provider name (e.g. :anthropic, :grok)."
  def api_key_for_provider(:fakeai), do: "fake"

  def api_key_for_provider(provider_name) when is_atom(provider_name) do
    case Map.get(@providers, provider_name) do
      %{key_providers: key_providers} -> active_api_key(key_providers)
      nil -> nil
    end
  end

  # -- stream_single --

  @spec stream_single(list(map() | Message.t()), on_event(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) and
             is_list(opts) do
    with {:ok, request} <- build_request(api_messages, opts) do
      provider_name = resolve_provider_name(opts[:provider], opts[:model])
      stream_with_retries(provider_name, request, on_event, opts, 0)
    end
  end

  defp stream_with_retries(provider_name, request, on_event, opts, attempt) do
    case Client.stream_request(provider_name, request, on_event,
           receive_timeout: 60_000
         ) do
      {:error, reason} = error ->
        cfg = provider_app_config(provider_name)

        case retry_delay_ms(reason, attempt, opts, cfg) do
          nil ->
            error

          delay_ms ->
            Logger.warning(
              "#{provider_name} request retry #{attempt + 1}/#{max_retries(opts, cfg)} in #{delay_ms}ms: #{inspect(reason)}"
            )

            if delay_ms > 0, do: Process.sleep(delay_ms)

            stream_with_retries(
              provider_name,
              request,
              on_event,
              opts,
              attempt + 1
            )
        end

      result ->
        result
    end
  end

  defp retry_delay_ms(
         {:provider_error, _provider, error, _diagnostics},
         attempt,
         opts,
         cfg
       ) do
    if attempt < max_retries(opts, cfg) and retryable_error?(error) do
      compute_delay(attempt, opts, cfg)
    end
  end

  defp retry_delay_ms({:http_error, status, _decoded}, attempt, opts, cfg)
       when status in [429, 500, 502, 503, 504] do
    if attempt < max_retries(opts, cfg) do
      compute_delay(attempt, opts, cfg)
    end
  end

  defp retry_delay_ms(_reason, _attempt, _opts, _cfg), do: nil

  defp retryable_error?(%{"error" => %{} = error}),
    do: retryable_error?(error)

  defp retryable_error?(%{} = error) do
    type = error["type"] || error[:type]
    code = error["code"] || error[:code]

    message =
      String.downcase(to_string(error["message"] || error[:message] || ""))

    type in ["api_error", "overloaded_error", "rate_limit_error"] or
      code in ["rate_limit_exceeded", "server_error", "overloaded_error"] or
      String.contains?(message, "internal server error") or
      String.contains?(message, "overloaded") or
      String.contains?(message, "rate limit") or
      String.contains?(message, "try again later")
  end

  defp retryable_error?(_error), do: false

  defp compute_delay(attempt, opts, cfg) do
    base_ms = max(0, retry_base_ms(opts, cfg))
    max_ms = max(base_ms, retry_max_ms(opts, cfg))
    min(max_ms, base_ms * Integer.pow(2, attempt))
  end

  defp max_retries(opts, cfg),
    do:
      Keyword.get(
        opts,
        :max_retries,
        Keyword.get(cfg, :max_retries, @default_max_retries)
      )

  defp retry_base_ms(opts, cfg),
    do:
      Keyword.get(
        opts,
        :retry_base_ms,
        Keyword.get(cfg, :retry_base_ms, @default_retry_base_ms)
      )

  defp retry_max_ms(opts, cfg),
    do:
      Keyword.get(
        opts,
        :retry_max_ms,
        Keyword.get(cfg, :retry_max_ms, @default_retry_max_ms)
      )

  # -- Request building --

  @doc """
  Build a `%Request{}` from a list of API messages and caller opts.

  Public so test suites can verify the defaulting / opt-resolution
  logic directly without routing through `stream_single/3` and a
  provider fake. Production code should prefer `stream_single/3`.
  """
  @spec build_request(list(map() | Message.t()), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def build_request(api_messages, opts) do
    provider_name =
      resolve_provider_name(
        Keyword.get(opts, :provider),
        Keyword.get(opts, :model)
      )

    case Map.get(@providers, provider_name) do
      nil ->
        {:error, {:unknown_provider, opts[:provider] || opts[:model]}}

      provider_spec ->
        api_key = Keyword.get(opts, :api_key)

        if is_nil(api_key) or api_key == "" do
          {:error, :missing_api_key}
        else
          cfg = provider_app_config(provider_name)
          system = resolve_system(Keyword.get(opts, :system), cfg)
          model = Keyword.get(opts, :model, Keyword.get(cfg, :model))
          tools = Keyword.get(opts, :tools, Keyword.get(cfg, :tools, []))

          if is_nil(model) or model == "" do
            {:error, :missing_model}
          else
            {:ok,
             %Request{
               provider: provider_spec.provider_module,
               messages: api_messages,
               model: model,
               system: system,
               max_tokens:
                 Keyword.get(
                   opts,
                   :max_tokens,
                   Keyword.get(cfg, :max_tokens, @default_max_tokens)
                 ),
               tools: tools,
               thinking:
                 resolve_thinking(
                   model,
                   Keyword.get(opts, :thinking, Keyword.get(cfg, :thinking))
                 ),
               output_config: resolve_output_config(model, opts, cfg),
               cache_control:
                 resolve_cache_control(provider_name, api_messages, opts, cfg),
               response_modalities:
                 Keyword.get(
                   opts,
                   :response_modalities,
                   Keyword.get(cfg, :response_modalities)
                 ),
               response_format:
                 Keyword.get(
                   opts,
                   :response_format,
                   Keyword.get(cfg, :response_format)
                 ),
               response_mime_type:
                 Keyword.get(
                   opts,
                   :response_mime_type,
                   Keyword.get(cfg, :response_mime_type)
                 ),
               headers: build_headers(provider_spec, api_key, tools),
               endpoint:
                 build_endpoint(provider_spec, api_key, model, opts, cfg),
               parent_id: Keyword.get(opts, :parent_id),
               provider_options: %{
                 "reasoning_effort" =>
                   Keyword.get(opts, :effort, Keyword.get(cfg, :effort)),
                 "reasoning_summary" =>
                   Keyword.get(
                     opts,
                     :reasoning_summary,
                     Keyword.get(cfg, :reasoning_summary)
                   ),
                 "include_usage" => true,
                 "text_verbosity" =>
                   Keyword.get(opts, :verbosity, Keyword.get(cfg, :verbosity)),
                 "previous_response_id" =>
                   Keyword.get(opts, :previous_response_id)
               }
             }}
          end
        end
    end
  end

  defp resolve_system(system, cfg) do
    system = system || Keyword.get(cfg, :system, "")

    case String.trim(to_string(system)) do
      "" -> default_system_prompt()
      s -> s
    end
  end

  defp resolve_thinking(model, configured) when is_binary(model) do
    cond do
      is_map(configured) ->
        normalize_thinking(model, configured)

      is_nil(configured) and model == "claude-opus-4-6" ->
        %{"type" => "adaptive"}

      is_nil(configured) and model == "claude-opus-4-7" ->
        %{"type" => "adaptive", "display" => "summarized"}

      true ->
        configured
    end
  end

  defp resolve_thinking(_model, configured), do: configured

  defp normalize_thinking(model, configured)
       when is_binary(model) and is_map(configured) do
    configured =
      Map.new(configured, fn {key, value} ->
        {to_string(key), value}
      end)

    configured =
      if String.starts_with?(model, "claude-") do
        Map.put_new(configured, "type", "adaptive")
      else
        configured
      end

    if model == "claude-opus-4-7" do
      Map.put_new(configured, "display", "summarized")
    else
      configured
    end
  end

  defp resolve_output_config(model, opts, cfg) do
    output_config =
      Keyword.get(opts, :output_config, Keyword.get(cfg, :output_config))

    effort =
      opts
      |> Keyword.get(:effort, Keyword.get(cfg, :effort))

    if is_binary(effort) do
      (output_config || %{}) |> Map.put("effort", effort)
    else
      maybe_default_anthropic_output_config(model, output_config)
    end
  end

  defp maybe_default_anthropic_output_config("claude-opus-4-7", output_config) do
    (output_config || %{}) |> Map.put_new("effort", "xhigh")
  end

  defp maybe_default_anthropic_output_config(_model, output_config) do
    case output_config do
      %{} = config when map_size(config) > 0 -> config
      _ -> output_config
    end
  end

  @anthropic_version "2023-06-01"
  @context_beta "context-1m-2025-08-07"
  @mcp_beta "mcp-client-2025-11-20"

  defp build_headers(%{auth: :anthropic}, api_key, tools) do
    beta = [@context_beta]

    beta =
      if Enum.any?(List.wrap(tools), &mcp_tool?/1),
        do: beta ++ [@mcp_beta],
        else: beta

    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"anthropic-beta", Enum.join(beta, ",")},
      {"accept", "text/event-stream"}
    ]
  end

  defp build_headers(%{auth: :bearer}, api_key, _tools) do
    [{"authorization", "Bearer #{api_key}"}]
  end

  defp build_headers(%{auth: :query_key}, _api_key, _tools), do: []

  defp build_headers(%{auth: :none}, _api_key, _tools), do: []

  defp mcp_tool?(%{"type" => "mcp_endpoint"}), do: true
  defp mcp_tool?(_), do: false

  defp build_endpoint(
         %{auth: :query_key, endpoint: base},
         api_key,
         _model,
         opts,
         cfg
       ) do
    custom = Keyword.get(opts, :endpoint, Keyword.get(cfg, :endpoint))
    url = custom || base
    "#{String.trim_trailing(url, "/")}?alt=sse&key=#{api_key}"
  end

  defp build_endpoint(%{endpoint: base}, _api_key, _model, opts, cfg) do
    Keyword.get(opts, :endpoint, Keyword.get(cfg, :endpoint, base))
  end

  defp provider_app_config(provider_name) do
    case Map.get(@providers, provider_name) do
      %{config_key: nil} -> []
      %{config_key: key} -> Application.get_env(:froth, key, [])
      _ -> []
    end
  end

  # -- stream (low-level, used by Client) --

  @spec stream(Request.t(), on_event(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(request, on_event, opts \\ [])

  def stream(
        %Request{provider: Froth.LLM.Providers.Fake} = request,
        on_event,
        _opts
      )
      when is_function(on_event, 1) do
    Froth.LLM.Fake.stream(request, on_event)
  end

  def stream(%Request{} = request, on_event, opts)
      when is_function(on_event, 1) do
    provider = request.provider
    telemetry_provider = Keyword.get(opts, :provider_name, provider)
    on_edit = Keyword.get(opts, :on_edit, fn _edit -> :ok end)
    parent_id = request.parent_id || Keyword.get(opts, :parent_id)

    with true <- provider_module?(provider),
         {:ok, transport_request} <- provider.build_request(request) do
      initial = Store.new()

      SSE.stream(
        transport_request.url,
        transport_request.headers,
        transport_request.body,
        initial,
        fn payload, _raw, store ->
          {edits, done?} = provider.decode_payload(payload, store)
          store = Store.apply_edits(store, edits)

          Enum.each(edits, fn edit ->
            emit_edit(telemetry_provider, edit, parent_id)
            on_edit.(edit)

            case Edit.project_event(edit) do
              nil -> :ok
              event -> on_event.(event)
            end
          end)

          if done?, do: {:halt, store}, else: {:cont, store}
        end,
        Keyword.take(opts, [:receive_timeout, :finch])
      )
      |> case do
        {:ok, %{acc: store, diagnostics: diagnostics}} ->
          case provider_error_from_store(store) do
            nil ->
              {:ok,
               provider.finalize(store) |> Map.put(:diagnostics, diagnostics)}

            error ->
              {:error,
               {:provider_error, provider_name(provider), error, diagnostics}}
          end

        {:error, _} = err ->
          err
      end
    else
      false -> {:error, {:invalid_provider, provider}}
      {:error, _} = err -> err
    end
  end

  # -- active_api_key --

  @spec active_api_key(String.t() | atom() | [String.t() | atom()]) ::
          String.t() | nil
  def active_api_key(provider)
      when is_binary(provider) or is_atom(provider) or is_list(provider) do
    providers =
      provider
      |> List.wrap()
      |> Enum.map(&to_string/1)

    if providers == [] do
      nil
    else
      from(api_key in ApiKey,
        where: api_key.provider in ^providers,
        order_by: [desc: api_key.inserted_at],
        limit: 1,
        select: api_key.key
      )
      |> Froth.Repo.one()
    end
  end

  # -- Provider resolution --

  @spec resolve_provider_name(provider_ref(), String.t() | nil) ::
          atom() | nil
  def resolve_provider_name(provider, model \\ nil)

  def resolve_provider_name(nil, model), do: provider_name_for_model(model)

  def resolve_provider_name(provider, _model) when is_atom(provider) do
    if Map.has_key?(@providers, provider) do
      provider
    else
      normalize_provider_ref(Atom.to_string(provider))
    end
  end

  def resolve_provider_name(provider, _model) when is_binary(provider) do
    normalize_provider_ref(provider)
  end

  @spec provider_name_for_model(String.t() | nil) :: atom() | nil
  def provider_name_for_model(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "claude") -> :anthropic
      String.starts_with?(model, "grok") -> :grok
      String.starts_with?(model, "gemini") -> :gemini
      String.starts_with?(model, "gpt") -> :openai
      String.starts_with?(model, "chatgpt") -> :openai
      String.starts_with?(model, "o") -> :openai
      String.starts_with?(model, "fakeai-") -> :fakeai
      true -> nil
    end
  end

  def provider_name_for_model(_model), do: nil

  # -- Internal helpers --

  defp resolve_cache_control(provider_name, api_messages, opts, cfg) do
    cache_control =
      Keyword.get(
        opts,
        :cache_control,
        Keyword.get(cfg, :cache_control, %{"type" => "ephemeral"})
      )

    if provider_name == :anthropic and
         explicit_cache_breakpoints?(api_messages) do
      nil
    else
      cache_control
    end
  end

  defp explicit_cache_breakpoints?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %Message{content: content} -> content_has_cache_breakpoint?(content)
      %{"content" => content} -> content_has_cache_breakpoint?(content)
      %{content: content} -> content_has_cache_breakpoint?(content)
      _ -> false
    end)
  end

  defp explicit_cache_breakpoints?(_messages), do: false

  defp content_has_cache_breakpoint?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"cache_control" => %{} = _cache_control} -> true
      %{cache_control: %{} = _cache_control} -> true
      _ -> false
    end)
  end

  defp content_has_cache_breakpoint?(_content), do: false

  defp emit_edit(provider, %Edit{} = edit, parent_id) do
    Span.execute([:froth, :llm, :edit], parent_id, %{
      provider: provider_name(provider),
      op: edit.op,
      resource: edit.resource,
      path: edit.path,
      resource_id: Edit.resource_id(edit),
      full_path: Edit.full_path(edit),
      value: edit.value,
      attrs: edit.attrs,
      raw: edit.raw
    })
  end

  defp provider_name(provider)
       when provider in [:anthropic, :openai, :grok, :gemini] do
    provider
  end

  defp provider_name(provider) when is_atom(provider) do
    provider
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp provider_module?(provider) when is_atom(provider) do
    Code.ensure_loaded?(provider) and
      function_exported?(provider, :build_request, 1) and
      function_exported?(provider, :decode_payload, 2) and
      function_exported?(provider, :finalize, 1)
  end

  defp provider_module?(_provider), do: false

  defp provider_error_from_store(%Store{} = store) do
    case Store.get(store, ["message", "error"]) do
      %{} = error when map_size(error) > 0 -> error
      error when is_binary(error) and error != "" -> %{"message" => error}
      _ -> nil
    end
  end

  defp normalize_provider_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> String.downcase()
    |> case do
      "anthropic" -> :anthropic
      "claude" -> :anthropic
      "openai" -> :openai
      "gpt" -> :openai
      "grok" -> :grok
      "xai" -> :grok
      "gemini" -> :gemini
      "google" -> :gemini
      _ -> nil
    end
  end

  defp normalize_provider_ref(ref) when is_atom(ref), do: ref
end
