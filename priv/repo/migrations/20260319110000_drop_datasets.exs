defmodule Froth.Repo.Migrations.DropDatasets do
  use Ecto.Migration

  def up do
    drop(table(:datasets))
  end

  def down do
    create table(:datasets) do
      add(:name, :string, null: false)
      add(:format, :string, null: false, default: "trig")
      add(:data, :binary, null: false)
      add(:metadata, :map, default: %{})
      timestamps(type: :utc_datetime, updated_at: :updated_at)
    end

    create(index(:datasets, [:name]))
  end
end
