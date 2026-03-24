defmodule Froth.Search.OpenAI do
  @moduledoc false

  alias Froth.LLM.Message
  alias Froth.OpenAI

  def search(query, opts \\ []) when is_binary(query) do
    OpenAI.stream_single(
      [Message.user(Froth.Search.provider_prompt(query))],
      fn _event -> :ok end,
      model: opts[:model] || "gpt-5.4",
      system: Froth.Search.provider_system_prompt(),
      tools: [%{"type" => "web_search_preview"}]
    )
  end
end
