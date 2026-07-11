defmodule Froth.Repo.Migrations.AddUniqueWeeklyChronicleRanges do
  use Ecto.Migration

  def change do
    create(
      unique_index(:chat_summaries, [:chat_id, :from_date, :to_date],
        name: :chat_summaries_weekly_chronicle_range_index,
        where: "metadata->>'kind' = 'weekly_chronicle'"
      )
    )
  end
end
