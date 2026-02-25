defmodule Froth.Dataset.Stored do
  use Ecto.Schema
  import Ecto.Changeset

  schema "datasets" do
    field(:name, :string)
    field(:format, :string, default: "trig")
    field(:data, :binary)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime)
  end

  def changeset(stored, attrs) do
    stored
    |> cast(attrs, [:name, :format, :data, :metadata])
    |> validate_required([:name, :data])
  end
end
