defmodule Froth.Repo.Migrations.CreateCodexSessionRawEvents do
  use Ecto.Migration

  def change do
    create table(:codex_session_raw_events) do
      add(:session_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:method, :text)
      add(:payload, :map, null: false, default: %{})
      add(:raw_line, :text, null: false, default: "")
      add(:received_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:codex_session_raw_events, [:session_id, :id]))
    create(index(:codex_session_raw_events, [:session_id, :received_at]))
    create(index(:codex_session_raw_events, [:session_id, :kind, :method]))
  end
end
