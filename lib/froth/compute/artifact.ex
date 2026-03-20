defmodule Froth.Compute.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.ULID, autogenerate: true}

  schema "compute_artifacts" do
    field(:kind, :string)
    field(:uri, :string)
    field(:checksum, :string)
    field(:size, :integer)
    field(:metadata, :map, default: %{})

    belongs_to(:job, Froth.Compute.Job, type: Ecto.ULID)
    belongs_to(:task, Froth.Compute.Task, type: Ecto.ULID)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:job_id, :task_id, :kind, :uri, :checksum, :size, :metadata])
    |> validate_required([:job_id, :kind, :uri])
    |> validate_number(:size, greater_than_or_equal_to: 0)
  end
end
