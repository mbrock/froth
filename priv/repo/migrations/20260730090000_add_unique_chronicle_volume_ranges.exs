defmodule Froth.Repo.Migrations.AddUniqueChronicleVolumeRanges do
  use Ecto.Migration

  def change do
    create(
      unique_index(:chat_summaries, [:chat_id, :from_date, :to_date],
        name: :chat_summaries_chronicle_volume_range_index,
        where: "metadata->>'kind' = 'chronicle_volume'"
      )
    )
  end
end
