defmodule Froth.Repo.Migrations.AddLogsToReplicatePredictions do
  use Ecto.Migration

  def change do
    alter table(:replicate_predictions) do
      add :logs, :text
    end
  end
end
