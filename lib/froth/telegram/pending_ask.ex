defmodule Froth.Telegram.PendingAsk do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @foreign_key_type Ecto.ULID

  schema "telegram_pending_asks" do
    belongs_to(:cycle, Froth.Agent.Cycle)
    field(:bot_id, :string)
    field(:chat_id, :integer)
    field(:message_id, :integer)
    field(:tool_use_id, :string)
    field(:question, :string)
    field(:alternatives, {:array, :string}, default: [])
    field(:config, :map, source: :config_json, default: %{})
    field(:answer, :string)
    field(:answer_message_id, :integer)
    field(:answered_via, :string)
    field(:resolved_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pending_ask, attrs) do
    pending_ask
    |> cast(attrs, [
      :cycle_id,
      :bot_id,
      :chat_id,
      :message_id,
      :tool_use_id,
      :question,
      :alternatives,
      :config,
      :answer,
      :answer_message_id,
      :answered_via,
      :resolved_at
    ])
    |> validate_required([
      :cycle_id,
      :bot_id,
      :chat_id,
      :message_id,
      :tool_use_id,
      :question,
      :alternatives,
      :config
    ])
  end
end
