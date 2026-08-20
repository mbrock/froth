defmodule Froth.Repo.Migrations.CreateHostedVideos do
  use Ecto.Migration

  def change do
    create table(:hosted_videos) do
      add(:chat_id, :bigint, null: false)
      add(:message_id, :bigint, null: false)
      add(:object_key, :text, null: false)
      add(:public_url, :text, null: false)
      add(:content_type, :string, null: false)
      add(:content_length, :bigint, null: false)
      add(:announced_by, :string)
      add(:announcement_message_id, :bigint)
      add(:announced_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:hosted_videos, [:chat_id, :message_id]))
    create(unique_index(:hosted_videos, [:object_key]))
  end
end
