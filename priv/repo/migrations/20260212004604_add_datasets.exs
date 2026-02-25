defmodule Froth.Repo.Migrations.AddDatasets do
  use Ecto.Migration

  def change do
    create table(:datasets) do
      add :name, :string, null: false
      add :format, :string, null: false, default: "trig"
      add :data, :binary, null: false
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime, updated_at: :updated_at)
    end

    create unique_index(:datasets, [:name])
  end
end
