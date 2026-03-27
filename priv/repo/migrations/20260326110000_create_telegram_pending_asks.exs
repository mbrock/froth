defmodule Froth.Repo.Migrations.CreateTelegramPendingAsks do
  use Ecto.Migration

  def change do
    create table(:telegram_pending_asks, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:cycle_id, references(:agent_cycles, type: :uuid, on_delete: :delete_all), null: false)
      add(:bot_id, :string, null: false)
      add(:chat_id, :bigint, null: false)
      add(:message_id, :bigint, null: false)
      add(:tool_use_id, :string, null: false)
      add(:question, :text, null: false)
      add(:alternatives, {:array, :text}, null: false, default: [])
      add(:config_json, :jsonb, null: false, default: fragment("'{}'::jsonb"))
      add(:answer, :text)
      add(:answer_message_id, :bigint)
      add(:answered_via, :string)
      add(:resolved_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:telegram_pending_asks, [:cycle_id, :tool_use_id]))
    create(unique_index(:telegram_pending_asks, [:bot_id, :chat_id, :message_id]))
    create(index(:telegram_pending_asks, [:bot_id, :chat_id, :resolved_at, :inserted_at]))
  end
end
