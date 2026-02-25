defmodule Froth.Repo.Migrations.CreateAgentTables do
  use Ecto.Migration

  def change do
    create table(:agent_cycles, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      timestamps()
    end

    create table(:agent_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :role, :string, null: false
      add :content, :jsonb, null: false
      add :parent_id, references(:agent_messages, type: :uuid, on_delete: :nilify_all)
      timestamps()
    end

    create index(:agent_messages, [:parent_id])

    create table(:agent_events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :cycle_id, references(:agent_cycles, type: :uuid, on_delete: :delete_all), null: false
      add :head_id, references(:agent_messages, type: :uuid, on_delete: :nilify_all), null: false
      add :seq, :integer, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:agent_events, [:cycle_id, :seq])
  end
end
