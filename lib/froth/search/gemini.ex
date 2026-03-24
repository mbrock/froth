defmodule Froth.Search.Gemini do
  @moduledoc false

  alias Froth.Gemini
  alias Froth.LLM.Message

  def search(query, opts \\ []) when is_binary(query) do
    Gemini.stream_single(
      [Message.user(Froth.Search.provider_prompt(query))],
      fn _event -> :ok end,
      model: opts[:model] || "gemini-3.1-pro",
      system: Froth.Search.provider_system_prompt(),
      tools: [
        %{
          "type" => "google_search_retrieval",
          "dynamic_retrieval_config" => %{
            "mode" => "MODE_DYNAMIC",
            "dynamic_threshold" => 0.3
          }
        }
      ]
    )
  end
end
