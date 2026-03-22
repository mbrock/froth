defmodule Froth.LLM.Providers.OpenAICompat do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.Providers.OpenAI

  @impl true
  defdelegate build_request(request), to: OpenAI

  @impl true
  defdelegate decode_payload(payload, store), to: OpenAI

  @impl true
  defdelegate finalize(store), to: OpenAI

  @impl true
  defdelegate project_event(edit), to: OpenAI

  defdelegate encode_messages(messages), to: OpenAI
end
