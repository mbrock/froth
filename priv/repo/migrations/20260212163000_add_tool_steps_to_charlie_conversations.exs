defmodule Froth.Repo.Migrations.AddToolStepsToCharlieConversations do
  use Ecto.Migration

  def change do
    alter table(:charlie_conversations) do
      add(:tool_steps, :jsonb, default: "[]", null: false)
    end
  end
end
