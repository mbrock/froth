defmodule Froth.Compute.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running completed failed cancelled)

  @primary_key {:id, Ecto.ULID, autogenerate: true}

  schema "compute_jobs" do
    field(:type, :string)
    field(:status, :string, default: "pending")
    field(:label, :string)
    field(:args, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    field(:error, :string)

    has_many(:tasks, Froth.Compute.Task, foreign_key: :job_id)
    has_many(:artifacts, Froth.Compute.Artifact, foreign_key: :job_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :type,
      :status,
      :label,
      :args,
      :metadata,
      :started_at,
      :finished_at,
      :cancelled_at,
      :error
    ])
    |> validate_required([:type])
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
end
