defmodule Froth.Repo.Migrations.CreateSceneEvents do
  use Ecto.Migration

  def change do
    create table(:scene_events) do
      add :scene_id, :string, null: false
      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :author, :string
      add :seq, :bigserial

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:scene_events, [:scene_id, :seq])
    create index(:scene_events, [:scene_id, :type])
  end
end
