defmodule Froth.Repo.Migrations.DatasetsAllowMultiplePerName do
  use Ecto.Migration

  def change do
    drop unique_index(:datasets, [:name])
    create index(:datasets, [:name])
  end
end
