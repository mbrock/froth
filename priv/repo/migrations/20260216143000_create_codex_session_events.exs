defmodule Froth.Repo.Migrations.CreateCodexSessionEvents do
  use Ecto.Migration

  def change do
    create table(:codex_session_events) do
      add(:session_id, :text, null: false)
      add(:entry_id, :text, null: false)
      add(:sequence, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:body, :text, null: false, default: "")
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:codex_session_events, [:session_id, :entry_id]))
    create(index(:codex_session_events, [:session_id, :sequence]))
  end
end
