defmodule Froth.Agent.Event do
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          cycle_id: String.t(),
          head_id: String.t(),
          seq: integer()
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @foreign_key_type Ecto.ULID

  schema "agent_events" do
    belongs_to(:cycle, Froth.Agent.Cycle)
    belongs_to(:head, Froth.Agent.Message)
    field(:seq, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
