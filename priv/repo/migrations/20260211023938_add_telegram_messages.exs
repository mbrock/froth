defmodule Froth.Repo.Migrations.AddTelegramMessages do
  use Ecto.Migration

  def change do
    create table(:telegram_messages) do
      add :telegram_session_id, references(:telegram_sessions, type: :string, on_delete: :delete_all),
        null: false

      add :chat_id, :bigint, null: false
      add :message_id, :bigint, null: false
      add :sender_id, :bigint
      add :date, :integer, null: false
      add :raw, :jsonb, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:telegram_messages, [:telegram_session_id, :chat_id, :message_id])
    create index(:telegram_messages, [:chat_id, :date])
  end
end
