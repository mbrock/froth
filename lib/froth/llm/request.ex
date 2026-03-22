defmodule Froth.LLM.Request do
  @moduledoc false

  alias Froth.LLM.Message

  @type t :: %__MODULE__{
          provider: module(),
          messages: list(map() | Message.t()),
          model: String.t() | nil,
          system: String.t() | nil,
          max_tokens: pos_integer() | nil,
          tools: list(map()),
          thinking: map() | nil,
          output_config: map() | nil,
          cache_control: map() | nil,
          headers: [{String.t(), String.t()}],
          endpoint: String.t() | nil,
          provider_options: map(),
          parent_id: String.t() | nil
        }

  defstruct provider: nil,
            messages: [],
            model: nil,
            system: nil,
            max_tokens: nil,
            tools: [],
            thinking: nil,
            output_config: nil,
            cache_control: nil,
            headers: [],
            endpoint: nil,
            provider_options: %{},
            parent_id: nil
end
