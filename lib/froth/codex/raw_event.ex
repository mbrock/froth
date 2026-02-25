defmodule Froth.Codex.RawEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "codex_session_raw_events" do
    field(:session_id, :string)
    field(:kind, :string)
    field(:method, :string)
    field(:payload, :map, default: %{})
    field(:raw_line, :string, default: "")
    field(:received_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(raw_event, attrs) do
    raw_event
    |> cast(attrs, [:session_id, :kind, :method, :payload, :raw_line, :received_at])
    |> validate_required([:session_id, :kind, :payload, :raw_line, :received_at])
  end
end
