defmodule Froth.Repo.Migrations.AddExecutionSpineToAgentRuntime do
  use Ecto.Migration

  def up do
    alter table(:agent_cycles) do
      add :status, :string, null: false, default: "queued"
      add :provider, :string
      add :model, :string
      add :root_span_id, :string
      add :parent_span_id, :string
      add :config_json, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :system_prompt_hash, :string
      add :system_prompt_ref, :string
      add :toolset_hash, :string
      add :usage_json, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :cost_usd, :float
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
    end

    create index(:agent_cycles, [:status])
    create index(:agent_cycles, [:root_span_id])
    create index(:agent_cycles, [:inserted_at])

    alter table(:agent_events) do
      add :kind, :string, null: false, default: "message.appended"
      add :span_id, :string
      add :parent_span_id, :string
      add :message_id, references(:agent_messages, type: :uuid, on_delete: :nilify_all)
      add :tool_use_id, :string
      add :data_json, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :blob_ref, :string
    end

    execute """
    UPDATE agent_cycles
    SET
      status = 'completed',
      started_at = inserted_at AT TIME ZONE 'UTC',
      finished_at = COALESCE(updated_at, inserted_at) AT TIME ZONE 'UTC',
      config_json = COALESCE(config_json, '{}'::jsonb),
      usage_json = COALESCE(usage_json, '{}'::jsonb)
    """

    execute """
    UPDATE agent_events
    SET
      kind = 'message.appended',
      message_id = COALESCE(message_id, head_id),
      data_json = CASE
        WHEN data_json = '{}'::jsonb THEN jsonb_build_object('legacy_head_event', true)
        ELSE data_json
      END
    """

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
  end

  def down do
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
    JOIN agent_messages m ON m.id = e.head_id
    WHERE m.role = 'agent'
    GROUP BY e.cycle_id
    """

    drop index(:agent_events, [:span_id])
    drop index(:agent_events, [:cycle_id, :tool_use_id])
    drop index(:agent_events, [:cycle_id, :message_id])
    drop index(:agent_events, [:cycle_id, :kind])

    alter table(:agent_events) do
      remove :blob_ref
      remove :data_json
      remove :tool_use_id
      remove :message_id
      remove :parent_span_id
      remove :span_id
      remove :kind
    end

    drop index(:agent_cycles, [:inserted_at])
    drop index(:agent_cycles, [:root_span_id])
    drop index(:agent_cycles, [:status])

    alter table(:agent_cycles) do
      remove :finished_at
      remove :started_at
      remove :error
      remove :cost_usd
      remove :usage_json
      remove :toolset_hash
      remove :system_prompt_ref
      remove :system_prompt_hash
      remove :config_json
      remove :parent_span_id
      remove :root_span_id
      remove :model
      remove :provider
      remove :status
    end
  end
end
