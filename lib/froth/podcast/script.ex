defmodule Froth.Podcast.Script do
  use Ecto.Schema
  import Ecto.Changeset

  schema "podcast_scripts" do
    field(:batch_id, :string)
    field(:label, :string)
    field(:chat_id, :integer)
    field(:script, {:array, :map})
    field(:opts, :map, default: %{})
    field(:status, :string, default: "queued")

    timestamps(type: :utc_datetime)
  end

  def changeset(script, attrs) do
    script
    |> cast(attrs, [:batch_id, :label, :chat_id, :script, :opts, :status])
    |> validate_required([:batch_id, :script])
    |> unique_constraint(:batch_id)
  end
end
