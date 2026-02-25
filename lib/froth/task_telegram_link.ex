defmodule Froth.TaskTelegramLink do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_telegram_links" do
    field(:task_id, :string)
    field(:bot_id, :string)
    field(:chat_id, :integer)
    field(:message_id, :integer)
    field(:notify, :boolean, default: false)
    field(:expect_minutes, :integer)
    field(:notified_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :task_id,
      :bot_id,
      :chat_id,
      :message_id,
      :notify,
      :expect_minutes,
      :notified_at
    ])
    |> validate_required([:task_id, :bot_id])
  end
end
