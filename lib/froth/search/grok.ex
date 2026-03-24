defmodule Froth.Search.Grok do
  @moduledoc false

  alias Froth.Grok
  alias Froth.LLM.Message

  def search(query, opts \\ []) when is_binary(query) do
    Grok.stream_single(
      [Message.user(Froth.Search.provider_prompt(query))],
      fn _event -> :ok end,
      model: opts[:model] || "grok-4-1-fast-reasoning",
      system: Froth.Search.provider_system_prompt(),
      tools: [%{"type" => "x_search"}, %{"type" => "web_search"}]
    )
  end
end
