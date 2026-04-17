defmodule Froth.Repo.Migrations.CreateBlobs do
  use Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:bytes, :binary, null: false)
      add(:mime, :text, null: false, default: "text/plain")
      add(:size, :integer, null: false)
      add(:lines, :integer)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
