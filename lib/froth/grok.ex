defmodule Froth.Grok do
  @moduledoc false

  alias Froth.LLM
  alias Froth.LLM.Client
  alias Froth.LLM.Providers.{XAIChat, XAIResponses}
  alias Froth.LLM.Request

  @default_max_tokens 16_384
  @default_model "grok-4-1-fast-non-reasoning"
  @chat_endpoint "https://api.x.ai/v1/chat/completions"
  @responses_endpoint "https://api.x.ai/v1/responses"

  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    with {:ok, request} <- build_request(api_messages, opts) do
      Client.stream_request(:grok, request, on_event, receive_timeout: 60_000)
    end
  end

  defp build_request(api_messages, overrides) do
    cfg = Application.get_env(:froth, __MODULE__, [])

    api_key =
      Keyword.get(overrides, :api_key) ||
        Keyword.get(cfg, :api_key) ||
        LLM.active_api_key(["grok", "xai"])

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      tools = Keyword.get(overrides, :tools, Keyword.get(cfg, :tools, []))

      # Use Responses API when built-in tools (x_search, web_search) are present
      has_builtin_tools =
        Enum.any?(tools, fn
          %{"type" => t} when t in ["x_search", "web_search", "code_interpreter"] -> true
          _ -> false
        end)

      {provider, endpoint} =
        if has_builtin_tools do
          {XAIResponses, @responses_endpoint}
        else
          {XAIChat, @chat_endpoint}
        end

      {:ok,
       %Request{
         provider: provider,
         messages: api_messages,
         model: Keyword.get(overrides, :model, Keyword.get(cfg, :model, @default_model)),
         system: system_prompt(Keyword.get(overrides, :system, Keyword.get(cfg, :system, ""))),
         max_tokens:
           Keyword.get(overrides, :max_tokens, Keyword.get(cfg, :max_tokens, @default_max_tokens)),
         tools: tools,
         headers: [{"authorization", "Bearer #{api_key}"}],
         endpoint: Keyword.get(overrides, :endpoint, Keyword.get(cfg, :endpoint, endpoint)),
         provider_options: %{
           "reasoning_effort" => Keyword.get(overrides, :effort, Keyword.get(cfg, :effort))
         }
       }}
    end
  end

  defp system_prompt(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: LLM.default_system_prompt(), else: system
  end
end
