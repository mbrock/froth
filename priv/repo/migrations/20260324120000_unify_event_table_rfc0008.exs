defmodule Froth.Repo.Migrations.UnifyEventTableRfc0008 do
  use Ecto.Migration

  def up do
    rename table(:telemetry_events), to: table(:events)

    execute "ALTER INDEX telemetry_events_event_index RENAME TO events_event_index"
    execute "ALTER INDEX telemetry_events_inserted_at_index RENAME TO events_inserted_at_index"
    execute "ALTER INDEX telemetry_events_span_id_index RENAME TO events_span_id_index"
    execute "ALTER INDEX telemetry_events_parent_id_index RENAME TO events_parent_id_index"

    create index(:events, [:metadata], using: "gin")

    execute "DROP VIEW IF EXISTS cycle_usage"

    execute """
    CREATE VIEW cycle_usage AS
    SELECT
      (e.metadata->>'cycle_id')::uuid AS cycle_id,
      SUM(COALESCE((m.metadata->'usage'->>'input_tokens')::int, 0)) AS input_tokens,
      SUM(COALESCE((m.metadata->'usage'->>'output_tokens')::int, 0)) AS output_tokens,
      SUM(COALESCE((m.metadata->'usage'->>'cache_read_input_tokens')::int, 0)) AS cache_read_input_tokens,
      SUM(COALESCE((m.metadata->'usage'->>'cache_creation_input_tokens')::int, 0)) AS cache_creation_input_tokens,
      COUNT(*) FILTER (WHERE m.metadata->'usage' IS NOT NULL) AS turn_count
    FROM events e
    JOIN agent_messages m
      ON m.id = COALESCE(
        NULLIF(e.metadata->>'message_id', '')::uuid,
        NULLIF(e.metadata->>'head_id', '')::uuid
      )
    WHERE e.event = 'froth.agent.message.appended'
      AND e.event LIKE 'froth.agent.%'
      AND e.metadata->>'cycle_id' IS NOT NULL
      AND m.role = 'agent'
    GROUP BY (e.metadata->>'cycle_id')::uuid
    """

    drop table(:agent_events)
  end

  def down do
    create table(:agent_events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :cycle_id, references(:agent_cycles, type: :uuid, on_delete: :delete_all), null: false
      add :head_id, references(:agent_messages, type: :uuid, on_delete: :nilify_all), null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false, default: "message.appended"
      add :span_id, :string
      add :parent_span_id, :string
      add :message_id, references(:agent_messages, type: :uuid, on_delete: :nilify_all)
      add :tool_use_id, :string
      add :data_json, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :blob_ref, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:agent_events, [:cycle_id, :seq])
    create index(:agent_events, [:cycle_id, :kind])
    create index(:agent_events, [:cycle_id, :message_id])
    create index(:agent_events, [:cycle_id, :tool_use_id])
    create index(:agent_events, [:span_id])

    execute "DROP VIEW IF EXISTS cycle_usage"

    execute """
    CREATE VIEW cycle_usage AS
    SELECT
      e.cycle_id,
      SUM(COALESCE((m.metadata->'usage'->>'input_tokens')::int, 0)) AS input_tokens,
      SUM(COALESCE((m.metadata->'usage'->>'output_tokens')::int, 0)) AS output_tokens,
      SUM(COALESCE((m.metadata->'usage'->>'cache_read_input_tokens')::int, 0)) AS cache_read_input_tokens,
      SUM(COALESCE((m.metadata->'usage'->>'cache_creation_input_tokens')::int, 0)) AS cache_creation_input_tokens,
      COUNT(*) FILTER (WHERE m.metadata->'usage' IS NOT NULL) AS turn_count
    FROM agent_events e
    JOIN agent_messages m ON m.id = COALESCE(e.message_id, e.head_id)
    WHERE e.kind = 'message.appended' AND m.role = 'agent'
    GROUP BY e.cycle_id
    """

    drop index(:events, [:metadata])

    execute "ALTER INDEX events_event_index RENAME TO telemetry_events_event_index"
    execute "ALTER INDEX events_inserted_at_index RENAME TO telemetry_events_inserted_at_index"
    execute "ALTER INDEX events_span_id_index RENAME TO telemetry_events_span_id_index"
    execute "ALTER INDEX events_parent_id_index RENAME TO telemetry_events_parent_id_index"

    rename table(:events), to: table(:telemetry_events)
  end
end
