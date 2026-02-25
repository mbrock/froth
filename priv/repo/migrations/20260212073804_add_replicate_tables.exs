defmodule Froth.Repo.Migrations.AddReplicateTables do
  use Ecto.Migration

  def change do
    create table(:replicate_collections, primary_key: false) do
      add :slug, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :full_description, :text
      timestamps(type: :utc_datetime)
    end

    create table(:replicate_models, primary_key: false) do
      add :owner, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :run_count, :integer, default: 0
      add :visibility, :string, default: "public"
      add :is_official, :boolean, default: false
      add :url, :text
      add :cover_image_url, :text
      add :github_url, :text
      add :license_url, :text
      add :paper_url, :text
      add :input_schema, :map
      add :readme, :text
      add :collection_slug, references(:replicate_collections, column: :slug, type: :string)
      add :created_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:replicate_models, [:owner, :name])
    create index(:replicate_models, [:collection_slug])
    create index(:replicate_models, [:run_count])
  end
end
