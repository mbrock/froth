defmodule Froth.Repo.Migrations.CreateTelegramUsernames do
  use Ecto.Migration

  def change do
    create table(:telegram_usernames, primary_key: false) do
      add(:user_id, :bigint, primary_key: true)
      add(:username, :string)
      add(:first_name, :string)
      add(:last_name, :string)
      add(:label, :string, null: false)
      add(:source_session_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:telegram_usernames, [:username]))
  end
end
