defmodule Froth.Repo.Migrations.AddAnalyses do
  use Ecto.Migration

  def change do
    create table(:analyses) do
      add :type, :string, null: false
      add :chat_id, :bigint, null: false
      add :message_id, :bigint, null: false
      add :agent, :string, null: false
      add :analysis_text, :text, null: false
      add :metadata, :jsonb, default: "{}"
      add :generated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:analyses, [:type, :chat_id, :message_id, :agent])
    create index(:analyses, [:chat_id, :message_id])
    create index(:analyses, [:type])
  end
end
