defmodule Froth.Agent.Message.Content do
  @moduledoc """
  Ecto type for `Froth.Agent.Message.content`.

  At the application level, content is always a list of block maps — the shape
  the LLM APIs accept. At the database level, content is stored as a JSONB
  object `%{"_wrapped" => blocks}` so the column stays compatible with Ecto's
  `:map` type without a migration.

  This type handles the wrap/unwrap and also normalizes legacy shapes:

    - `"hello"` (plain string) → `[%{"type" => "text", "text" => "hello"}]`
    - `%{"_wrapped" => "hello"}` (legacy string row) → same
    - `%{"_wrapped" => [...]}` (legacy block-list row) → `[...]`
    - `[...]` (already normalized) → unchanged
    - `nil` / empty / unknown → `[]`

  Consumers should never see `_wrapped` — if they do, the type failed.
  """

  use Ecto.Type

  @wrapped_key "_wrapped"

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: {:ok, to_blocks(value)}

  @impl true
  def load(value), do: {:ok, to_blocks(value)}

  @impl true
  def dump(value), do: {:ok, %{@wrapped_key => to_blocks(value)}}

  @impl true
  def embed_as(_format), do: :self

  @impl true
  def equal?(a, b), do: to_blocks(a) == to_blocks(b)

  @doc """
  Normalize an arbitrary content value into a canonical list of block maps.

  Safe to call on values that are already normalized (identity on lists).
  """
  @spec to_blocks(term()) :: [map()]
  def to_blocks(nil), do: []
  def to_blocks(""), do: []
  def to_blocks(text) when is_binary(text), do: [text_block(text)]
  def to_blocks(blocks) when is_list(blocks), do: blocks
  def to_blocks(%{@wrapped_key => inner}), do: to_blocks(inner)
  def to_blocks(%{"type" => _} = block), do: [block]
  def to_blocks(%{} = map) when map_size(map) == 0, do: []
  def to_blocks(%{} = map), do: [map]
  def to_blocks(_other), do: []

  defp text_block(text), do: %{"type" => "text", "text" => text}
end
