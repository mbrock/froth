defmodule Froth.OpenAI do
  @moduledoc false

  alias Froth.LLM
  alias Froth.LLM.Client
  alias Froth.LLM.Providers.OpenAI, as: OpenAIProvider
  alias Froth.LLM.Request

  @default_max_tokens 16_384
  @default_model "gpt-5-mini"
  @endpoint "https://api.openai.com/v1/chat/completions"

  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    with {:ok, request} <- build_request(api_messages, opts) do
      Client.stream_request(:openai, request, on_event, receive_timeout: 60_000)
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
      {:ok,
       %Request{
         provider: OpenAIProvider,
         messages: api_messages,
         model: Keyword.get(overrides, :model, Keyword.get(cfg, :model, @default_model)),
         system: system_prompt(Keyword.get(overrides, :system, Keyword.get(cfg, :system, ""))),
         max_tokens:
           Keyword.get(overrides, :max_tokens, Keyword.get(cfg, :max_tokens, @default_max_tokens)),
         tools: Keyword.get(overrides, :tools, Keyword.get(cfg, :tools, [])),
         headers: [{"authorization", "Bearer #{api_key}"}],
         endpoint: Keyword.get(overrides, :endpoint, Keyword.get(cfg, :endpoint, @endpoint)),
         provider_options: %{
           "include_usage" => true,
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
