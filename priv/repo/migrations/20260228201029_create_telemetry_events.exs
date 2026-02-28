defmodule Froth.Repo.Migrations.CreateTelemetryEvents do
  use Ecto.Migration

  def change do
    create table(:telemetry_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :event, :string, null: false
      add :measurements, :map, default: %{}
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:telemetry_events, [:event])
    create index(:telemetry_events, [:inserted_at])
  end
end
