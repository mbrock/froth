defmodule Froth.Repo.Migrations.AddSha256ToBlobs do
  use Ecto.Migration

  def change do
    alter table(:blobs) do
      add(:sha256, :binary)
    end

    create(unique_index(:blobs, [:sha256]))
  end
end
