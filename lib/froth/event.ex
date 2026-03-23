defmodule Froth.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t() | nil,
          event: String.t() | nil,
          span_id: String.t() | nil,
          parent_id: String.t() | nil,
          measurements: map(),
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "events" do
    field(:event, :string)
    field(:span_id, :string)
    field(:parent_id, :string)
    field(:measurements, :map, default: %{})
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event, :span_id, :parent_id, :measurements, :metadata])
    |> validate_required([:event])
  end
end
