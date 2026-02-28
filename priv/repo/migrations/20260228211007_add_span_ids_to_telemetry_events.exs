defmodule Froth.Repo.Migrations.AddSpanIdsToTelemetryEvents do
  use Ecto.Migration

  def change do
    alter table(:telemetry_events) do
      add :span_id, :string
      add :parent_id, :string
    end

    create index(:telemetry_events, [:span_id])
    create index(:telemetry_events, [:parent_id])
  end
end
