defmodule Froth.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_keys" do
    field(:name, :string)
    field(:provider, :string)
    field(:key, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :provider, :key])
    |> validate_required([:name, :provider, :key])
    |> unique_constraint(:name)
  end

  def get(name) do
    Froth.Repo.get_by(__MODULE__, name: name)
  end
end
