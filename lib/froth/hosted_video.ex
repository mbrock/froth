defmodule Froth.HostedVideo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hosted_videos" do
    field(:chat_id, :integer)
    field(:message_id, :integer)
    field(:object_key, :string)
    field(:public_url, :string)
    field(:content_type, :string)
    field(:content_length, :integer)
    field(:announced_by, :string)
    field(:announcement_message_id, :integer)
    field(:announced_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(video, attrs) do
    video
    |> cast(attrs, [
      :chat_id,
      :message_id,
      :object_key,
      :public_url,
      :content_type,
      :content_length,
      :announced_by,
      :announcement_message_id,
      :announced_at
    ])
    |> validate_required([
      :chat_id,
      :message_id,
      :object_key,
      :public_url,
      :content_type,
      :content_length
    ])
    |> unique_constraint([:chat_id, :message_id])
    |> unique_constraint(:object_key)
  end
end
