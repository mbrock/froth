defmodule Froth.Agent.Message do
  alias Froth.Agent.Message.Content
  alias LLM.Message, as: LLMMessage

  @type t :: %__MODULE__{
          id: String.t() | nil,
          cycle_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          role: :user | :agent,
          content: [map()],
          metadata: map() | nil,
          inserted_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :cycle_id,
    :seq,
    :role,
    :content,
    :metadata,
    :inserted_at
  ]

  def user(content),
    do: %__MODULE__{role: :user, content: Content.to_blocks(content)}

  def agent(content),
    do: %__MODULE__{role: :agent, content: Content.to_blocks(content)}

  def agent(content, metadata),
    do: %__MODULE__{
      role: :agent,
      content: Content.to_blocks(content),
      metadata: metadata
    }

  def to_api(%__MODULE__{role: :user, content: content}) do
    %{"role" => "user", "content" => content}
  end

  def to_api(%__MODULE__{role: :agent, content: content}) do
    %{"role" => "assistant", "content" => content}
  end

  def to_llm_message(%__MODULE__{role: :user, content: content}) do
    LLMMessage.user(content)
  end

  def to_llm_message(%__MODULE__{role: :agent, content: content}) do
    LLMMessage.assistant(content)
  end

  @doc """
  Normalize a value into the canonical block-list shape.

  Kept as a convenience for callers that construct `%Message{}` structs
  directly without going through `user/1` or `agent/1`.
  """
  @spec wrap(term()) :: [map()]
  def wrap(value), do: Content.to_blocks(value)

  @doc "Extract concatenated text blocks, returning nil if there is none."
  @spec extract_text(t() | [map()] | binary() | nil) :: String.t() | nil
  def extract_text(%__MODULE__{content: content}), do: extract_text(content)

  def extract_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  def extract_text(text) when is_binary(text), do: text
  def extract_text(_), do: nil
end
