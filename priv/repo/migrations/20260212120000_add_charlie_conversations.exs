defmodule Froth.Repo.Migrations.AddCharlieConversations do
  use Ecto.Migration

  def change do
    create table(:charlie_conversations) do
      add :chat_id, :bigint, null: false
      add :reply_to, :bigint
      add :api_messages, :jsonb, default: "[]"
      add :pending_tools, :jsonb, default: "[]"
      add :status, :string, null: false, default: "pending"
      timestamps()
    end

    create index(:charlie_conversations, [:status])
    create index(:charlie_conversations, [:chat_id])
  end
end
