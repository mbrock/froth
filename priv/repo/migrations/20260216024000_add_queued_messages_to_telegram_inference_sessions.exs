defmodule Froth.Repo.Migrations.AddQueuedMessagesToTelegramInferenceSessions do
  use Ecto.Migration

  def change do
    alter table(:telegram_inference_sessions) do
      add(:queued_messages, :jsonb, default: "[]", null: false)
    end
  end
end
