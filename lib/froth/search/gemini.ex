defmodule Froth.Search.Gemini do
  @moduledoc false

  alias Froth.Gemini
  alias Froth.LLM.Message

  def search(query, opts \\ []) when is_binary(query) do
    Gemini.stream_single(
      [Message.user(Froth.Search.provider_prompt(query))],
      fn _event -> :ok end,
      model: opts[:model] || "gemini-3.1-flash-lite-preview",
      system: Froth.Search.provider_system_prompt(),
      tools: [%{"google_search" => %{}}]
    )
  end
end
