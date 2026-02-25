defmodule Froth.Repo.Migrations.NormalizeMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :chat_session_id, references(:chat_sessions, type: :string, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :role, :string, null: false
      add :content, :jsonb, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:chat_session_id, :position], unique: true)

    # Migrate existing JSONB data into rows.
    # Old format has "text" (string), new format has "content" (string or array).
    execute(
      """
      INSERT INTO messages (chat_session_id, position, role, content, inserted_at)
      SELECT
        s.id,
        (row_number() OVER (PARTITION BY s.id ORDER BY idx)) - 1,
        msg->>'role',
        CASE
          WHEN msg ? 'content' THEN msg->'content'
          WHEN msg ? 'text' THEN msg->'text'
          ELSE '"?"'::jsonb
        END,
        s.inserted_at
      FROM chat_sessions s,
           jsonb_array_elements(s.messages) WITH ORDINALITY AS t(msg, idx)
      WHERE jsonb_array_length(s.messages) > 0
      """,
      """
      UPDATE chat_sessions s SET messages = (
        SELECT coalesce(jsonb_agg(
          jsonb_build_object('role', m.role, 'content', m.content)
          ORDER BY m.position
        ), '[]'::jsonb)
        FROM messages m WHERE m.chat_session_id = s.id
      )
      """
    )

    alter table(:chat_sessions) do
      remove :messages, :jsonb, default: "[]"
    end
  end
end
