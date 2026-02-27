defmodule Froth.Repo.Migrations.CreateTelegramCycleLinks do
  use Ecto.Migration

  def change do
    create table(:telegram_cycle_links, primary_key: false) do
      add :cycle_id, references(:agent_cycles, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :bot_id, :string, null: false
      add :chat_id, :bigint, null: false
      add :reply_to, :bigint
      add :legacy_inference_session_id, :bigint

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:telegram_cycle_links, [:bot_id, :chat_id])
    create index(:telegram_cycle_links, [:legacy_inference_session_id], where: "legacy_inference_session_id IS NOT NULL")
  end
end
