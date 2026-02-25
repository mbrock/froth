defmodule Froth.JsonbType do
  @moduledoc "Ecto type that accepts any JSON-encodable value (string, list, map, etc.)"
  use Ecto.Type

  def type, do: :jsonb

  def cast(value), do: {:ok, value}
  def load(value), do: {:ok, value}
  def dump(value), do: {:ok, value}
end
