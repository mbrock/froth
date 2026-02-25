defmodule Froth.Repo.Migrations.AddApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :key, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_keys, [:name])
  end
end
