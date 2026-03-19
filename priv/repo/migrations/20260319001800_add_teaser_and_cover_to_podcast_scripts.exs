defmodule Froth.Repo.Migrations.AddTeaserAndCoverToPodcastScripts do
  use Ecto.Migration

  def change do
    alter table(:podcast_scripts) do
      add :teaser, :text
      add :cover_url, :string
    end
  end
end
