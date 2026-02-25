defmodule Froth.Repo.Migrations.RenameCharlieConversationsToTelegramInferenceSessions do
  use Ecto.Migration

  def change do
    rename(table(:charlie_conversations), to: table(:telegram_inference_sessions))
  end
end
