defmodule LLM do
  @moduledoc false

  require Logger

  alias LLM.{Client, Edit, Request, Store}
  alias LLM.Transport.SSE
  alias Span
  alias LLM.{Fake, Message}

  @type on_event :: (term() -> any())
  @type on_edit :: (Edit.t() -> any())
  @type provider_ref :: atom() | String.t() | module() | nil

  @default_max_retries 5
  @default_retry_base_ms 2_000
  @default_retry_max_ms 30_000

  # -- Provider registry --

  @providers %{
    anthropic: %{
      provider_module: LLM.Providers.Anthropic,
      endpoint: "https://api.anthropic.com/v1/messages",
      auth: :anthropic
    },
    openai: %{
      provider_module: LLM.Providers.OpenAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      auth: :bearer
    },
    grok: %{
      provider_module: LLM.Providers.OpenAIResponses,
      endpoint: "https://api.x.ai/v1/responses",
      auth: :bearer
    },
    gemini: %{
      provider_module: LLM.Providers.GeminiInteractions,
      endpoint:
        "https://generativelanguage.googleapis.com/v1beta/interactions",
      auth: :query_key
    },
    fakeai: %{
      provider_module: LLM.Providers.Fake,
      endpoint: "fake://",
      auth: :none
    }
  }

  # -- stream_single --

  @spec stream_single(list(map() | Message.t()), on_event(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) and
             is_list(opts) do
    with {:ok, request} <- build_request(api_messages, opts) do
      provider_name = resolve_provider_name(opts[:provider], nil)
      stream_with_retries(provider_name, request, on_event, opts, 0)
    end
  end

  defp stream_with_retries(provider_name, request, on_event, opts, attempt) do
    case Client.stream_request(provider_name, request, on_event,
           receive_timeout: 60_000
         ) do
      {:error, reason} = error ->
        case retry_delay_ms(reason, attempt, opts) do
          nil ->
            error

          delay_ms ->
            Logger.warning(
              "#{provider_name} request retry #{attempt + 1}/#{max_retries(opts)} in #{delay_ms}ms: #{inspect(reason)}"
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
         opts
       ) do
    if attempt < max_retries(opts) and retryable_error?(error) do
      compute_delay(attempt, opts)
    end
  end

  defp retry_delay_ms({:http_error, status, _decoded}, attempt, opts)
       when status in [429, 500, 502, 503, 504] do
    if attempt < max_retries(opts) do
      compute_delay(attempt, opts)
    end
  end

  defp retry_delay_ms(_reason, _attempt, _opts), do: nil

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

  defp compute_delay(attempt, opts) do
    base_ms = max(0, retry_base_ms(opts))
    max_ms = max(base_ms, retry_max_ms(opts))
    min(max_ms, base_ms * Integer.pow(2, attempt))
  end

  defp max_retries(opts),
    do: Keyword.get(opts, :max_retries, @default_max_retries)

  defp retry_base_ms(opts),
    do: Keyword.get(opts, :retry_base_ms, @default_retry_base_ms)

  defp retry_max_ms(opts),
    do: Keyword.get(opts, :retry_max_ms, @default_retry_max_ms)

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
    with {:ok, provider_name} <- fetch_provider_name(opts),
         {:ok, provider_spec} <-
           fetch_provider_spec(provider_name, opts[:provider]),
         {:ok, api_key} <- fetch_api_key(opts),
         {:ok, model} <- fetch_model(opts) do
      tools = Keyword.get(opts, :tools, [])
      effort = Keyword.get(opts, :effort)

      {:ok,
       %Request{
         provider: provider_spec.provider_module,
         messages: api_messages,
         model: model,
         system: normalize_system(Keyword.get(opts, :system)),
         max_tokens: Keyword.get(opts, :max_tokens),
         tools: tools,
         thinking: normalize_thinking(Keyword.get(opts, :thinking)),
         output_config:
           normalize_output_config(
             Keyword.get(opts, :output_config),
             effort
           ),
         cache_control:
           resolve_cache_control(provider_name, api_messages, opts),
         response_modalities: Keyword.get(opts, :response_modalities),
         response_format: Keyword.get(opts, :response_format),
         response_mime_type: Keyword.get(opts, :response_mime_type),
         headers: build_headers(provider_spec, api_key),
         endpoint: build_endpoint(provider_spec, api_key, opts),
         parent_id: Keyword.get(opts, :parent_id),
         provider_options: %{
           "reasoning_effort" => effort,
           "reasoning_summary" => Keyword.get(opts, :reasoning_summary),
           "include_usage" => true,
           "text_verbosity" => Keyword.get(opts, :verbosity),
           "previous_response_id" => Keyword.get(opts, :previous_response_id)
         }
       }}
    end
  end

  defp normalize_thinking(configured) when is_map(configured) do
    configured =
      Map.new(configured, fn {key, value} ->
        {to_string(key), value}
      end)

    if map_size(configured) == 0, do: nil, else: configured
  end

  defp normalize_thinking(_configured), do: nil

  defp normalize_output_config(output_config, effort) do
    if is_binary(effort) do
      (output_config || %{}) |> Map.put("effort", effort)
    else
      normalize_optional_map(output_config)
    end
  end

  defp normalize_system(system) when is_binary(system), do: system
  defp normalize_system(nil), do: nil
  defp normalize_system(system), do: to_string(system)

  defp normalize_optional_map(%{} = map) when map_size(map) > 0, do: map
  defp normalize_optional_map(_map), do: nil

  @anthropic_version "2023-06-01"

  defp build_headers(%{auth: :anthropic}, api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"accept", "text/event-stream"}
    ]
  end

  defp build_headers(%{auth: :bearer}, api_key) do
    [{"authorization", "Bearer #{api_key}"}]
  end

  defp build_headers(%{auth: :query_key}, _api_key), do: []

  defp build_headers(%{auth: :none}, _api_key), do: []

  defp build_endpoint(%{auth: :query_key, endpoint: base}, api_key, opts) do
    url = Keyword.get(opts, :endpoint) || base
    "#{String.trim_trailing(url, "/")}?alt=sse&key=#{api_key}"
  end

  defp build_endpoint(%{endpoint: base}, _api_key, opts) do
    Keyword.get(opts, :endpoint, base)
  end

  # -- stream (low-level, used by Client) --

  @spec stream(Request.t(), on_event(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(request, on_event, opts \\ [])

  def stream(
        %Request{provider: LLM.Providers.Fake} = request,
        on_event,
        _opts
      )
      when is_function(on_event, 1) do
    Fake.stream(request, on_event)
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

  defp resolve_cache_control(provider_name, api_messages, opts) do
    cache_control = Keyword.get(opts, :cache_control)

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
       when provider in [:anthropic, :openai, :grok, :gemini, :fakeai] do
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
      "fakeai" -> :fakeai
      _ -> nil
    end
  end

  defp normalize_provider_ref(ref) when is_atom(ref), do: ref

  defp fetch_api_key(opts) do
    case Keyword.get(opts, :api_key) do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :missing_model}
    end
  end

  defp fetch_provider_name(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} ->
        case resolve_provider_name(provider, nil) do
          nil -> {:error, {:unknown_provider, provider}}
          provider_name -> {:ok, provider_name}
        end

      :error ->
        {:error, :missing_provider}
    end
  end

  defp fetch_provider_spec(provider_name, provider_ref) do
    case Map.get(@providers, provider_name) do
      nil -> {:error, {:unknown_provider, provider_ref}}
      provider_spec -> {:ok, provider_spec}
    end
  end
end
