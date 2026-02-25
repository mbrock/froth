defmodule Froth.Replicate.Collection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:slug, :string, autogenerate: false}
  schema "replicate_collections" do
    field(:name, :string)
    field(:description, :string)
    field(:full_description, :string)
    has_many(:models, Froth.Replicate.Model, foreign_key: :collection_slug)
    timestamps(type: :utc_datetime)
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:slug, :name, :description, :full_description])
    |> validate_required([:slug, :name])
  end
end
