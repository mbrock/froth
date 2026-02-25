defmodule Froth.Repo.Migrations.CreateChatSessions do
  use Ecto.Migration

  def change do
    create table(:chat_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :messages, :jsonb, null: false, default: "[]"
      timestamps(type: :utc_datetime)
    end
  end
end
