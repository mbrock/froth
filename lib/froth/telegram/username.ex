defmodule Froth.Telegram.Username do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:user_id, :integer, autogenerate: false}

  schema "telegram_usernames" do
    field(:username, :string)
    field(:first_name, :string)
    field(:last_name, :string)
    field(:label, :string)
    field(:source_session_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(username, attrs) do
    username
    |> cast(attrs, [
      :user_id,
      :username,
      :first_name,
      :last_name,
      :label,
      :source_session_id
    ])
    |> validate_required([:user_id, :label])
  end
end
