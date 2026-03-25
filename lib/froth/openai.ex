defmodule Froth.OpenAI do
  @moduledoc false

  require Logger

  alias Froth.LLM
  alias Froth.LLM.Client
  alias Froth.LLM.Providers.OpenAIResponses
  alias Froth.LLM.Request

  @default_max_tokens 16_384
  @default_model "gpt-5-mini"
  @default_max_retries 5
  @default_retry_base_ms 2_000
  @default_retry_max_ms 30_000
  @responses_endpoint "https://api.openai.com/v1/responses"

  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    cfg = Application.get_env(:froth, __MODULE__, [])

    with {:ok, request} <- build_request(api_messages, opts) do
      stream_request_with_retries(request, on_event, opts, cfg, 0)
    end
  end

  defp build_request(api_messages, overrides) do
    cfg = Application.get_env(:froth, __MODULE__, [])

    api_key =
      Keyword.get(overrides, :api_key) ||
        LLM.active_api_key("openai") ||
        Keyword.get(cfg, :api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      tools = Keyword.get(overrides, :tools, Keyword.get(cfg, :tools, []))

      {:ok,
       %Request{
         provider: OpenAIResponses,
         messages: api_messages,
         model: Keyword.get(overrides, :model, Keyword.get(cfg, :model, @default_model)),
         system: system_prompt(Keyword.get(overrides, :system, Keyword.get(cfg, :system, ""))),
         max_tokens:
           Keyword.get(overrides, :max_tokens, Keyword.get(cfg, :max_tokens, @default_max_tokens)),
         tools: tools,
         headers: [{"authorization", "Bearer #{api_key}"}],
         endpoint:
           Keyword.get(overrides, :endpoint, Keyword.get(cfg, :endpoint, @responses_endpoint)),
         parent_id: Keyword.get(overrides, :parent_id),
         provider_options: %{
           "include_usage" => true,
           "reasoning_effort" => Keyword.get(overrides, :effort, Keyword.get(cfg, :effort)),
           "reasoning_summary" =>
             Keyword.get(overrides, :reasoning_summary, Keyword.get(cfg, :reasoning_summary)),
           "text_verbosity" => Keyword.get(overrides, :verbosity, Keyword.get(cfg, :verbosity)),
           "previous_response_id" => Keyword.get(overrides, :previous_response_id)
         }
       }}
    end
  end

  defp system_prompt(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: LLM.default_system_prompt(), else: system
  end

  defp stream_request_with_retries(request, on_event, opts, cfg, attempt)
       when is_integer(attempt) and attempt >= 0 do
    case Client.stream_request(:openai, request, on_event, receive_timeout: 60_000) do
      {:error, reason} = error ->
        case retry_delay_ms(reason, attempt, opts, cfg) do
          nil ->
            error

          delay_ms ->
            Logger.warning(
              "OpenAI request retry #{attempt + 1}/#{max_retries(opts, cfg)} in #{delay_ms}ms: " <>
                retry_reason_summary(reason)
            )

            if delay_ms > 0, do: Process.sleep(delay_ms)
            stream_request_with_retries(request, on_event, opts, cfg, attempt + 1)
        end

      result ->
        result
    end
  end

  defp retry_delay_ms({:provider_error, "openai", error, _diagnostics}, attempt, opts, cfg)
       when is_integer(attempt) do
    if attempt < max_retries(opts, cfg) and retryable_openai_error?(error) do
      base_ms = max(0, retry_base_ms(opts, cfg))
      max_ms = max(base_ms, retry_max_ms(opts, cfg))
      min(max_ms, base_ms * Integer.pow(2, attempt))
    end
  end

  defp retry_delay_ms(_reason, _attempt, _opts, _cfg), do: nil

  defp retryable_openai_error?(%{"error" => %{} = error}), do: retryable_openai_error?(error)

  defp retryable_openai_error?(%{} = error) do
    code = error["code"] || error[:code]
    type = error["type"] || error[:type]
    message = String.downcase(to_string(error["message"] || error[:message] || ""))

    code in ["rate_limit_exceeded", "server_error", "overloaded_error"] or
      type in ["rate_limit_exceeded", "tokens", "server_error", "overloaded_error"] or
      String.contains?(message, "rate limit") or
      String.contains?(message, "try again later")
  end

  defp retryable_openai_error?(_error), do: false

  defp retry_reason_summary({:provider_error, "openai", error, _diagnostics}) do
    provider_error_summary(error)
  end

  defp retry_reason_summary(reason), do: inspect(reason)

  defp provider_error_summary(%{"error" => %{} = error}), do: provider_error_summary(error)

  defp provider_error_summary(%{} = error) do
    [
      error["code"] || error[:code],
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
