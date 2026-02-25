defmodule Froth.Analysis do
  use Ecto.Schema
  import Ecto.Changeset

  schema "analyses" do
    field(:type, :string)
    field(:chat_id, :integer)
    field(:message_id, :integer)
    field(:agent, :string)
    field(:analysis_text, :string)
    field(:metadata, :map, default: %{})
    field(:generated_at, :utc_datetime)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(analysis, attrs) do
    analysis
    |> cast(attrs, [
      :type,
      :chat_id,
      :message_id,
      :agent,
      :analysis_text,
      :metadata,
      :generated_at
    ])
    |> validate_required([:type, :chat_id, :message_id, :agent, :analysis_text, :generated_at])
    |> unique_constraint([:type, :chat_id, :message_id, :agent])
  end
end
