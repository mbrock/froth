defmodule Froth.Repo.Migrations.AddBotIdToTelegramInferenceSessions do
  use Ecto.Migration

  def change do
    alter table(:telegram_inference_sessions) do
      add(:bot_id, :string, null: false, default: "charlie")
    end

    create(index(:telegram_inference_sessions, [:bot_id]))
    create(index(:telegram_inference_sessions, [:bot_id, :chat_id]))
  end
end
