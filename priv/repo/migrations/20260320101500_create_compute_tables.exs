defmodule Froth.Repo.Migrations.CreateComputeTables do
  use Ecto.Migration

  def change do
    create table(:compute_jobs, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:type, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:label, :text)
      add(:args, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:cancelled_at, :utc_datetime_usec)
      add(:error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:compute_jobs, [:type, :status]))
    create(index(:compute_jobs, [:status, :inserted_at]))

    create table(:compute_tasks, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:job_id, references(:compute_jobs, type: :uuid, on_delete: :delete_all), null: false)
      add(:stage, :text)
      add(:kind, :text, null: false)
      add(:worker_type, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:priority, :integer, null: false, default: 0)
      add(:payload, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:attempt, :integer, null: false, default: 0)
      add(:max_attempts, :integer, null: false, default: 3)
      add(:lease_token, :text)
      add(:worker_id, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_heartbeat_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:compute_tasks, [:job_id, :status]))
    create(index(:compute_tasks, [:worker_type, :status, :priority, :inserted_at]))
    create(index(:compute_tasks, [:worker_id, :status]))
    create(index(:compute_tasks, [:lease_expires_at]))

    create table(:compute_artifacts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:job_id, references(:compute_jobs, type: :uuid, on_delete: :delete_all), null: false)
      add(:task_id, references(:compute_tasks, type: :uuid, on_delete: :delete_all))
      add(:kind, :text, null: false)
      add(:uri, :text, null: false)
      add(:checksum, :text)
      add(:size, :bigint)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:compute_artifacts, [:job_id, :inserted_at]))
    create(index(:compute_artifacts, [:task_id, :inserted_at]))
  end
end
