defmodule Froth.Repo.Migrations.DropWebChatTables do
  use Ecto.Migration

  def change do
    drop_if_exists(table(:messages))
    drop_if_exists(table(:chat_sessions))
  end
end
