defmodule Froth.LLM.Providers.XAIChat do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.Providers.OpenAICompat

  @impl true
  defdelegate build_request(request), to: OpenAICompat

  @impl true
  defdelegate decode_payload(payload, store), to: OpenAICompat

  @impl true
  defdelegate finalize(store), to: OpenAICompat

  @impl true
  defdelegate project_event(edit), to: OpenAICompat

  defdelegate encode_messages(messages), to: OpenAICompat
end
