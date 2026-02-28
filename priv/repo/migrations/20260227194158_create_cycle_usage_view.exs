defmodule Froth.Repo.Migrations.CreateCycleUsageView do
  use Ecto.Migration

  def up do
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
  end

  def down do
    execute "DROP VIEW IF EXISTS cycle_usage"
  end
end
