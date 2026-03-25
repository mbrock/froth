defmodule Froth.Gemini do
  @moduledoc false

  alias Froth.LLM
  alias Froth.LLM.Client
  alias Froth.LLM.Providers.Gemini, as: GeminiProvider
  alias Froth.LLM.Providers.GeminiInteractions
  alias Froth.LLM.Request

  @default_max_tokens 16_384
  @default_model "gemini-3-flash-preview"
  @models_endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @interactions_endpoint "https://generativelanguage.googleapis.com/v1beta/interactions"

  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) do
    with {:ok, request} <- build_request(api_messages, opts) do
      Client.stream_request(:gemini, request, on_event, receive_timeout: 60_000)
    end
  end

  defp build_request(api_messages, overrides) do
    cfg = Application.get_env(:froth, __MODULE__, [])

    api_key =
      Keyword.get(overrides, :api_key) ||
        Keyword.get(cfg, :api_key) ||
        LLM.active_api_key(["gemini", "google"])

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      provider = request_provider(api_messages, overrides, cfg)
      model = request_model(overrides, cfg)

      {:ok,
       %Request{
         provider: provider,
         messages: api_messages,
         model: model,
         system: system_prompt(Keyword.get(overrides, :system, Keyword.get(cfg, :system, ""))),
         max_tokens:
           Keyword.get(overrides, :max_tokens, Keyword.get(cfg, :max_tokens, @default_max_tokens)),
         response_modalities:
           Keyword.get(
             overrides,
             :response_modalities,
             Keyword.get(cfg, :response_modalities)
           ),
         response_format:
           Keyword.get(overrides, :response_format, Keyword.get(cfg, :response_format)),
         response_mime_type:
           Keyword.get(overrides, :response_mime_type, Keyword.get(cfg, :response_mime_type)),
         tools: Keyword.get(overrides, :tools, Keyword.get(cfg, :tools, [])),
         headers: [],
         endpoint: request_endpoint(provider, overrides, cfg, model, api_key),
         provider_options: %{
           "reasoning_effort" => Keyword.get(overrides, :effort, Keyword.get(cfg, :effort))
         }
       }}
    end
  end

  defp build_models_endpoint(base, model, api_key) when is_binary(base) and is_binary(model) do
    base = String.trim_trailing(base, "/")
    "#{base}/#{model}:streamGenerateContent?alt=sse&key=#{api_key}"
  end

  defp build_interactions_endpoint(base, api_key) when is_binary(base) do
    base = String.trim_trailing(base, "/")
    "#{base}?alt=sse&key=#{api_key}"
  end

  defp request_endpoint(GeminiInteractions, overrides, cfg, _model, api_key) do
    Keyword.get(overrides, :endpoint) ||
      Keyword.get(cfg, :interactions_endpoint) ||
      build_interactions_endpoint(@interactions_endpoint, api_key)
  end

  defp request_endpoint(_provider, overrides, cfg, model, api_key) do
    Keyword.get(overrides, :endpoint) ||
      Keyword.get(cfg, :endpoint) ||
      build_models_endpoint(@models_endpoint, model, api_key)
  end

  defp request_provider(api_messages, overrides, cfg) do
    if interactions_requested?(api_messages, overrides, cfg) do
      GeminiInteractions
    else
      GeminiProvider
    end
  end

  defp request_model(overrides, cfg) do
    Keyword.get(overrides, :model, Keyword.get(cfg, :model, @default_model))
  end

  defp interactions_requested?(api_messages, overrides, cfg) do
    present?(Keyword.get(overrides, :response_modalities, Keyword.get(cfg, :response_modalities))) or
      present?(Keyword.get(overrides, :response_format, Keyword.get(cfg, :response_format))) or
      present?(Keyword.get(overrides, :response_mime_type, Keyword.get(cfg, :response_mime_type))) or
      Enum.any?(api_messages, &message_has_media_content?/1)
  end

  defp message_has_media_content?(message) do
    case LLM.Message.normalize(message) do
      {:ok, normalized} ->
        normalized
        |> LLM.Message.content_blocks()
        |> Enum.any?(&content_block_has_media?/1)

      :error ->
        false
    end
  end

  defp content_block_has_media?(%{"type" => type})
       when type in ["image", "audio", "document", "video"],
       do: true

  defp content_block_has_media?(%{"content" => content}) when is_list(content),
    do: Enum.any?(content, &content_block_has_media?/1)

  defp content_block_has_media?(_block), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp system_prompt(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: LLM.default_system_prompt(), else: system
  end
end
