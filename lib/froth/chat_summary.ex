defmodule Froth.ChatSummary do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_summaries" do
    field(:chat_id, :integer)
    field(:from_date, :integer)
    field(:to_date, :integer)
    field(:agent, :string)
    field(:summary_text, :string)
    field(:message_count, :integer)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, [
      :chat_id,
      :from_date,
      :to_date,
      :agent,
      :summary_text,
      :message_count,
      :metadata
    ])
    |> validate_required([
      :chat_id,
      :from_date,
      :to_date,
      :agent,
      :summary_text,
      :message_count
    ])
    |> unique_constraint([:chat_id, :from_date, :to_date],
      name: :chat_summaries_weekly_chronicle_range_index
    )
  end
end
