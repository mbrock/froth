defmodule Froth.Agent.ToolUse do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{id: String.t(), name: String.t(), input: map()}

  @primary_key false
  embedded_schema do
    field(:id, :string)
    field(:name, :string)
    field(:input, :map, default: %{})
  end

  def from_api(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id, :name, :input])
    |> validate_required([:id, :name])
    |> apply_action!(:validate)
  end
end
