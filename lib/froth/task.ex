defmodule Froth.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:task_id, :string, autogenerate: false}

  schema "tasks" do
    field(:type, :string)
    field(:status, :string, default: "pending")
    field(:label, :string)
    field(:metadata, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:max_attempts, :integer, default: 1)

    has_many(:events, Froth.TaskEvent, foreign_key: :task_id, references: :task_id)
    has_many(:telegram_links, Froth.TaskTelegramLink, foreign_key: :task_id, references: :task_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :task_id,
      :type,
      :status,
      :label,
      :metadata,
      :started_at,
      :finished_at,
      :attempts,
      :max_attempts
    ])
    |> validate_required([:task_id, :type])
    |> validate_inclusion(:status, ~w(pending running completed failed stopped))
  end
end
