defmodule Froth.LLM.Providers.OpenAI do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.Providers.OpenAIResponses

  @impl true
  defdelegate build_request(request), to: OpenAIResponses

  @impl true
  defdelegate decode_payload(payload, store), to: OpenAIResponses

  @impl true
  defdelegate finalize(store), to: OpenAIResponses

  @impl true
  defdelegate project_event(edit), to: OpenAIResponses
end
