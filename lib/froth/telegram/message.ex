defmodule Froth.Telegram.Message do
  @moduledoc """
  The `telegram_messages` Ecto schema, plus a small set of pure helpers
  for navigating TDLib message / update / callback-query payloads.

  Each helper (`chat_id/1`, `message_id/1`, `sender_user_id/1`,
  `text/1`, `reply_to_message_id/1`) accepts any reasonable TDLib shape
  and returns `nil` when the field isn't present.
  """

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
    |> cast(attrs, [
      :telegram_session_id,
      :chat_id,
      :message_id,
      :sender_id,
      :date,
      :raw
    ])
    |> validate_required([
      :telegram_session_id,
      :chat_id,
      :message_id,
      :date,
      :raw
    ])
    |> unique_constraint([:telegram_session_id, :chat_id, :message_id])
  end

  # -- Payload navigation helpers -------------------------------------

  @doc "Chat id from a raw message, an update wrapping a message, or a callback query."
  def chat_id(%{"chat_id" => id}) when is_integer(id), do: id
  def chat_id(%{"message" => %{"chat_id" => id}}) when is_integer(id), do: id
  def chat_id(_payload), do: nil

  @doc """
  Message id.

  For a raw message this is the `\"id\"` field. For a callback query it is
  either `\"message_id\"` (top-level) or `message.id`.
  """
  def message_id(%{"message_id" => id}) when is_integer(id), do: id
  def message_id(%{"message" => %{"id" => id}}) when is_integer(id), do: id
  def message_id(%{"id" => id}) when is_integer(id), do: id
  def message_id(_payload), do: nil

  @doc """
  Resolve the sending user id from a raw message or a callback query.

  Callback queries carry a flat `\"sender_user_id\"`, whereas regular
  messages nest it inside `\"sender_id\"`. Returns `nil` for chat-based
  senders (use `extract_sender_id/1` if you need chat senders too).
  """
  def sender_user_id(%{"sender_user_id" => uid}) when is_integer(uid), do: uid

  def sender_user_id(%{"sender_id" => %{"user_id" => uid}})
      when is_integer(uid), do: uid

  def sender_user_id(_payload), do: nil

  @doc "Extract plain text from a message's content (text or caption)."
  def text(%{"content" => %{"text" => %{"text" => text}}})
      when is_binary(text), do: text

  def text(%{"content" => %{"caption" => %{"text" => text}}})
      when is_binary(text), do: text

  def text(_payload), do: nil

  @doc "The message id this message replies to, or `nil`."
  def reply_to_message_id(%{
        "reply_to" => %{
          "@type" => "messageReplyToMessage",
          "message_id" => id
        }
      })
      when is_integer(id),
      do: id

  def reply_to_message_id(_payload), do: nil

  @doc """
  Forward attribution from a TDLib message, or `nil` for non-forwards.

  Returns a map shaped like:

      %{kind: :user,    user_id: 12345}
      %{kind: :hidden,  name: "Mr Satya Humbaba"}
      %{kind: :chat,    chat_id: -100..., signature: "Pavel Durov" | nil}
      %{kind: :channel, chat_id: -100..., message_id: 13631488, signature: nil}
  """
  def forward_info(%{
        "forward_info" => %{"origin" => %{"@type" => type} = origin}
      }) do
    case type do
      "messageOriginUser" ->
        %{kind: :user, user_id: origin["sender_user_id"]}

      "messageOriginHiddenUser" ->
        %{kind: :hidden, name: origin["sender_name"]}

      "messageOriginChat" ->
        %{
          kind: :chat,
          chat_id: origin["sender_chat_id"],
          signature: present(origin["author_signature"])
        }

      "messageOriginChannel" ->
        %{
          kind: :channel,
          chat_id: origin["chat_id"],
          message_id: origin["message_id"],
          signature: present(origin["author_signature"])
        }

      _ ->
        nil
    end
  end

  def forward_info(_payload), do: nil

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value

  @doc "Extract sender_id (user or chat) from a TDLib message map."
  def extract_sender_id(%{"sender_id" => %{"user_id" => uid}}), do: uid
  def extract_sender_id(%{"sender_id" => %{"chat_id" => cid}}), do: cid
  def extract_sender_id(_), do: nil
end
