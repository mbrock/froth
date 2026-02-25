defmodule Froth.Inference.InferenceSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "telegram_inference_sessions" do
    field(:bot_id, :string)
    field(:chat_id, :integer)
    field(:reply_to, :integer)
    field(:api_messages, {:array, :map}, default: [])
    field(:pending_tools, {:array, :map}, default: [])
    field(:queued_messages, {:array, :map}, default: [])
    field(:tool_steps, {:array, :map}, default: [])
    field(:status, :string, default: "pending")
    timestamps()
  end

  def changeset(inference_session, attrs) do
    inference_session
    |> cast(attrs, [
      :bot_id,
      :chat_id,
      :reply_to,
      :api_messages,
      :pending_tools,
      :queued_messages,
      :tool_steps,
      :status
    ])
    |> validate_required([:bot_id, :chat_id, :status])
  end
end
