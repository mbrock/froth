defmodule Froth.Repo.Migrations.CreatePodcastScripts do
  use Ecto.Migration

  def change do
    create table(:podcast_scripts) do
      add :batch_id, :string, null: false
      add :label, :string
      add :chat_id, :bigint
      add :script, :jsonb, null: false
      add :opts, :jsonb, default: "{}"
      add :status, :string, default: "queued"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:podcast_scripts, [:batch_id])
  end
end
