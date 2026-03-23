defmodule Froth.Agent.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t() | nil,
          cycle_id: String.t(),
          head_id: String.t() | nil,
          seq: integer(),
          kind: String.t(),
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          message_id: String.t() | nil,
          tool_use_id: String.t() | nil,
          data: map(),
          blob_ref: String.t() | nil
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @foreign_key_type Ecto.ULID

  schema "agent_events" do
    belongs_to(:cycle, Froth.Agent.Cycle)
    belongs_to(:head, Froth.Agent.Message)
    belongs_to(:message, Froth.Agent.Message)
    field(:seq, :integer)
    field(:kind, :string, default: "message.appended")
    field(:span_id, :string)
    field(:parent_span_id, :string)
    field(:tool_use_id, :string)
    field(:data, :map, source: :data_json, default: %{})
    field(:blob_ref, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :cycle_id,
      :head_id,
      :message_id,
      :seq,
      :kind,
      :span_id,
      :parent_span_id,
      :tool_use_id,
      :data,
      :blob_ref
    ])
    |> validate_required([:cycle_id, :seq, :kind])
  end
end
