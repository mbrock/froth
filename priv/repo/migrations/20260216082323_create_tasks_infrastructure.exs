defmodule Froth.Repo.Migrations.CreateTasksInfrastructure do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :task_id, :text, primary_key: true
      add :type, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :label, :text
      add :metadata, :map, default: %{}
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:tasks, [:type, :status])
    create index(:tasks, [:status, :inserted_at])

    create table(:task_events) do
      add :task_id, references(:tasks, column: :task_id, type: :text, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :kind, :text, null: false
      add :content, :text, null: false, default: ""
      add :emitted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:task_events, [:task_id, :sequence])
    create index(:task_events, [:task_id, :emitted_at])

    create table(:task_telegram_links) do
      add :task_id, references(:tasks, column: :task_id, type: :text, on_delete: :delete_all),
        null: false

      add :bot_id, :text, null: false
      add :chat_id, :bigint
      add :message_id, :bigint
      add :notify, :boolean, null: false, default: false
      add :expect_minutes, :integer
      add :notified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:task_telegram_links, [:task_id])
    create index(:task_telegram_links, [:bot_id, :chat_id])
    create index(:task_telegram_links, [:notify, :notified_at])
  end
end
