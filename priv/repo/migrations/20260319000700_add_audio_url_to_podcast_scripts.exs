defmodule Froth.Repo.Migrations.AddAudioUrlToPodcastScripts do
  use Ecto.Migration

  def change do
    alter table(:podcast_scripts) do
      add :audio_url, :string
    end
  end
end
