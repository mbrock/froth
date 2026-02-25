defmodule Froth.Repo.Migrations.AddChatSummaries do
  use Ecto.Migration

  def change do
    create table(:chat_summaries) do
      add :chat_id, :bigint, null: false
      add :from_date, :integer, null: false
      add :to_date, :integer, null: false
      add :agent, :string, null: false
      add :summary_text, :text, null: false
      add :message_count, :integer, null: false
      add :metadata, :jsonb, default: "{}"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:chat_summaries, [:chat_id])
    create index(:chat_summaries, [:chat_id, :from_date, :to_date])
  end
end
