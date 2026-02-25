defmodule Froth.Repo.Migrations.CreateStreams do
  use Ecto.Migration

  def change do
    create table(:streams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :rate, :integer, null: false
      timestamps()
    end
  end
end
