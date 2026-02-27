defmodule Froth.Telegram.CycleLink do
  use Ecto.Schema

  @primary_key false

  schema "telegram_cycle_links" do
    belongs_to(:cycle, Froth.Agent.Cycle, type: Ecto.ULID, primary_key: true)
    field(:bot_id, :string)
    field(:chat_id, :integer)
    field(:reply_to, :integer)
    field(:legacy_inference_session_id, :integer)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
