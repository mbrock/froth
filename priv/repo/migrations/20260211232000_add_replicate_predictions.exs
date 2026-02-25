defmodule Froth.Repo.Migrations.AddReplicatePredictions do
  use Ecto.Migration

  def change do
    create table(:replicate_predictions) do
      add :model, :string, null: false
      add :prompt, :text
      add :input, :map, null: false, default: %{}
      add :status, :string, null: false, default: "starting"
      add :replicate_id, :string
      add :output, :map
      add :error, :text
      add :metrics, :map
      timestamps(type: :utc_datetime, updated_at: false)
      add :completed_at, :utc_datetime
    end

    create index(:replicate_predictions, [:status])
    create index(:replicate_predictions, [:replicate_id], unique: true, where: "replicate_id IS NOT NULL")
  end
end
