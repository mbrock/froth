defmodule Froth.TaskEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_events" do
    field(:task_id, :string)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:content, :string, default: "")
    field(:emitted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:task_id, :sequence, :kind, :content, :emitted_at])
    |> validate_required([:task_id, :sequence, :kind, :emitted_at])
  end
end
