defmodule Froth.Telegram.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "telegram_messages" do
    field(:telegram_session_id, :string)
    field(:chat_id, :integer)
    field(:message_id, :integer)
    field(:sender_id, :integer)
    field(:date, :integer)
    field(:raw, :map)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:telegram_session_id, :chat_id, :message_id, :sender_id, :date, :raw])
    |> validate_required([:telegram_session_id, :chat_id, :message_id, :date, :raw])
    |> unique_constraint([:telegram_session_id, :chat_id, :message_id])
  end

  @doc "Extract sender_id from a TDLib message map."
  def extract_sender_id(%{"sender_id" => %{"user_id" => uid}}), do: uid
  def extract_sender_id(%{"sender_id" => %{"chat_id" => cid}}), do: cid
  def extract_sender_id(_), do: nil
end
