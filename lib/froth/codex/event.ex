defmodule Froth.Codex.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "codex_session_events" do
    field(:session_id, :string)
    field(:entry_id, :string)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:body, :string, default: "")
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:session_id, :entry_id, :sequence, :kind, :body, :metadata])
    |> validate_required([:session_id, :entry_id, :sequence, :kind])
  end
end
