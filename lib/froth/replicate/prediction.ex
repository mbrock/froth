defmodule Froth.Replicate.Prediction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "replicate_predictions" do
    field(:model, :string)
    field(:prompt, :string)
    field(:input, :map, default: %{})
    field(:status, :string, default: "starting")
    field(:replicate_id, :string)
    field(:output, :map)
    field(:error, :string)
    field(:logs, :string)
    field(:metrics, :map)
    field(:completed_at, :utc_datetime)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [
      :model,
      :prompt,
      :input,
      :status,
      :replicate_id,
      :output,
      :error,
      :logs,
      :metrics,
      :completed_at
    ])
    |> validate_required([:model, :input])
  end
end
