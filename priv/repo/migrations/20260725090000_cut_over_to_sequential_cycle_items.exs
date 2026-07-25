defmodule Froth.Repo.Migrations.CutOverToSequentialCycleItems do
  use Ecto.Migration

  def up do
    create table(:cycle_items, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)

      add(
        :cycle_id,
        references(:agent_cycles, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:seq, :bigint, null: false)
      add(:role, :string)
      add(:item_kind, :string, null: false)
      add(:payload, :jsonb, null: false, default: fragment("'{}'::jsonb"))
      add(:span_id, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:cycle_items, [:cycle_id, :seq]))
    create(index(:cycle_items, [:cycle_id, :item_kind, :seq]))

    execute("DROP VIEW IF EXISTS cycle_usage")
    execute("DROP INDEX IF EXISTS events_agent_message_cycle_seq_head_idx")

    rename(table(:agent_messages), to: table(:agent_messages_archive))
  end

  def down do
    raise "the sequential cycle-item cutover is intentionally irreversible"
  end
end
