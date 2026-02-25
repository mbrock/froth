defmodule Froth.Agent.Cycle do
  use Ecto.Schema

  @type t :: %__MODULE__{id: String.t() | nil}

  @primary_key {:id, Ecto.ULID, autogenerate: true}

  schema "agent_cycles" do
    timestamps()
  end
end
