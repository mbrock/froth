defmodule Froth.Repo.Migrations.AddAgentContextLookupIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute(create_events_index_sql())
    execute(create_cycle_links_index_sql())
  end

  def down do
    execute(drop_index_sql("events_agent_message_cycle_seq_head_idx"))
    execute(drop_index_sql("telegram_cycle_links_chat_reply_to_bot_idx"))
  end

  defp create_events_index_sql do
    """
    CREATE INDEX #{concurrently_clause()} IF NOT EXISTS events_agent_message_cycle_seq_head_idx
    ON events (
      ((metadata->>'cycle_id')),
      (COALESCE((metadata->>'seq')::bigint, 0)) DESC,
      ((metadata->>'head_id'))
    )
    WHERE event = 'froth.agent.message.appended'
      AND metadata->>'cycle_id' IS NOT NULL
      AND metadata->>'head_id' IS NOT NULL
    """
  end

  defp create_cycle_links_index_sql do
    """
    CREATE INDEX #{concurrently_clause()} IF NOT EXISTS telegram_cycle_links_chat_reply_to_bot_idx
    ON telegram_cycle_links (chat_id, reply_to, bot_id)
    WHERE reply_to IS NOT NULL
    """
  end

  defp drop_index_sql(name) do
    "DROP INDEX #{concurrently_clause()} IF EXISTS #{name}"
  end

  defp concurrently_clause do
    if sandbox_repo?(), do: "", else: "CONCURRENTLY"
  end

  defp sandbox_repo? do
    Application.get_env(:froth, Froth.Repo, [])[:pool] == Ecto.Adapters.SQL.Sandbox
  end
end
