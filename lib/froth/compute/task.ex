defmodule Froth.Compute.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending running completed failed cancelled)

  @primary_key {:id, Ecto.ULID, autogenerate: true}

  schema "compute_tasks" do
    field(:stage, :string)
    field(:kind, :string)
    field(:worker_type, :string)
    field(:status, :string, default: "pending")
    field(:priority, :integer, default: 0)
    field(:payload, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:attempt, :integer, default: 0)
    field(:max_attempts, :integer, default: 3)
    field(:lease_token, :string)
    field(:worker_id, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:error, :string)

    belongs_to(:job, Froth.Compute.Job, type: Ecto.ULID)
    has_many(:artifacts, Froth.Compute.Artifact, foreign_key: :task_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :job_id,
      :stage,
      :kind,
      :worker_type,
      :status,
      :priority,
      :payload,
      :metadata,
      :attempt,
      :max_attempts,
      :lease_token,
      :worker_id,
      :lease_expires_at,
      :last_heartbeat_at,
      :started_at,
      :finished_at,
      :error
    ])
    |> validate_required([:job_id, :kind, :worker_type])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
  end

  def statuses, do: @statuses
end
