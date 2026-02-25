defmodule Froth.Repo.Migrations.AddTelegramSessions do
  use Ecto.Migration

  def change do
    create table(:telegram_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :api_id, :integer, null: false
      add :api_hash, :string, null: false
      add :bot_token, :string
      add :phone_number, :string
      add :database_dir, :string
      add :files_dir, :string
      add :enabled, :boolean, default: true, null: false

      timestamps()
    end
  end
end
