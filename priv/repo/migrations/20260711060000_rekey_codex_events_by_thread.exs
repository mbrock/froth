defmodule Froth.Repo.Migrations.RekeyCodexEventsByThread do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE codex_session_events AS events
    SET session_id = mapping.thread_id
    FROM (
      SELECT DISTINCT
        metadata->>'session_id' AS session_id,
        metadata->>'thread_id' AS thread_id
      FROM tasks
      WHERE type = 'codex'
        AND metadata->>'session_id' IS NOT NULL
        AND metadata->>'thread_id' IS NOT NULL
    ) AS mapping
    WHERE events.session_id = mapping.session_id
    """)

    execute("""
    UPDATE codex_session_raw_events AS events
    SET session_id = mapping.thread_id
    FROM (
      SELECT DISTINCT
        metadata->>'session_id' AS session_id,
        metadata->>'thread_id' AS thread_id
      FROM tasks
      WHERE type = 'codex'
        AND metadata->>'session_id' IS NOT NULL
        AND metadata->>'thread_id' IS NOT NULL
    ) AS mapping
    WHERE events.session_id = mapping.session_id
    """)
  end

  def down do
    :ok
  end
end
