defmodule Froth.Replicate.Model do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "replicate_models" do
    field(:owner, :string, primary_key: true)
    field(:name, :string, primary_key: true)
    field(:description, :string)
    field(:run_count, :integer, default: 0)
    field(:visibility, :string, default: "public")
    field(:is_official, :boolean, default: false)
    field(:url, :string)
    field(:cover_image_url, :string)
    field(:github_url, :string)
    field(:license_url, :string)
    field(:paper_url, :string)
    field(:input_schema, :map)
    field(:readme, :string)
    field(:created_at, :utc_datetime)

    belongs_to(:collection, Froth.Replicate.Collection,
      foreign_key: :collection_slug,
      references: :slug,
      type: :string
    )

    timestamps(type: :utc_datetime)
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :owner,
      :name,
      :description,
      :run_count,
      :visibility,
      :is_official,
      :url,
      :cover_image_url,
      :github_url,
      :license_url,
      :paper_url,
      :input_schema,
      :readme,
      :collection_slug,
      :created_at
    ])
    |> validate_required([:owner, :name])
  end

  def slug(%__MODULE__{owner: owner, name: name}), do: "#{owner}/#{name}"
end
