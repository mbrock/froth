defmodule Froth.Repo.Migrations.IndexAgentEventsByCycleSequence do
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS events_agent_cycle_seq_idx")

    execute("""
    CREATE INDEX events_agent_cycle_seq_idx
    ON events (
      ((metadata->>'cycle_id')),
      (COALESCE((metadata->>'seq')::bigint, -1))
    )
    WHERE event LIKE 'froth.agent.%'
      AND metadata->>'cycle_id' IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS events_agent_cycle_seq_idx")
  end
end
