defmodule Froth.Repo.Migrations.CreateWikiEntries do
  use Ecto.Migration

  def change do
    create table(:wiki_entries) do
      add :slug, :string, null: false
      add :title, :string, null: false
      add :also_known_as, :string
      add :body, :text, null: false, default: ""
      add :see_also, {:array, :string}, default: []
      timestamps()
    end

    create unique_index(:wiki_entries, [:slug])
  end
end
