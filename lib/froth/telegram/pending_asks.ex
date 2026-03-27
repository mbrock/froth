defmodule Froth.Telegram.PendingAsks do
  @moduledoc false

  import Ecto.Query

  alias Froth.Repo
  alias Froth.Telegram.PendingAsk

  def create(attrs) when is_map(attrs) do
    %PendingAsk{}
    |> PendingAsk.changeset(attrs)
    |> Repo.insert()
  end

  def get(id) when is_binary(id), do: Repo.get(PendingAsk, id)
  def get(_id), do: nil

  def get_unresolved_by_message(bot_id, chat_id, message_id)
      when is_binary(bot_id) and is_integer(chat_id) and is_integer(message_id) do
    Repo.one(
      from(p in PendingAsk,
        where:
          p.bot_id == ^bot_id and p.chat_id == ^chat_id and p.message_id == ^message_id and
            is_nil(p.resolved_at),
        limit: 1
      ),
      log: false
    )
  end

  def get_unresolved_by_message(_bot_id, _chat_id, _message_id), do: nil

  def latest_unresolved(bot_id, chat_id)
      when is_binary(bot_id) and is_integer(chat_id) do
    Repo.one(
      from(p in PendingAsk,
        where: p.bot_id == ^bot_id and p.chat_id == ^chat_id and is_nil(p.resolved_at),
        order_by: [desc: p.inserted_at],
        limit: 1
      ),
      log: false
    )
  end

  def latest_unresolved(_bot_id, _chat_id), do: nil

  def resolve(pending_ask, answer, opts \\ [])

  def resolve(%PendingAsk{id: id} = pending_ask, answer, opts)
      when is_binary(id) and is_binary(answer) and is_list(opts) do
    answer_message_id =
      case Keyword.get(opts, :answer_message_id) do
        value when is_integer(value) -> value
        _ -> nil
      end

    answered_via =
      case Keyword.get(opts, :answered_via) do
        value when is_binary(value) and value != "" -> value
        _ -> "message"
      end

    now = DateTime.utc_now()

    config_merge =
      case Keyword.get(opts, :config_merge) do
        value when is_map(value) -> value
        _ -> %{}
      end

    updated_config =
      pending_ask.config
      |> Kernel.||(%{})
      |> Map.merge(config_merge)

    {count, _rows} =
      from(p in PendingAsk, where: p.id == ^id and is_nil(p.resolved_at))
      |> Repo.update_all(
        set: [
          config: updated_config,
          answer: answer,
          answer_message_id: answer_message_id,
          answered_via: answered_via,
          resolved_at: now,
          updated_at: now
        ]
      )

    case count do
      1 ->
        {:ok,
         %{
           pending_ask
           | answer: answer,
             config: updated_config,
             answer_message_id: answer_message_id,
             answered_via: answered_via,
             resolved_at: now
         }}

      _ ->
        {:error, :already_resolved}
    end
  end

  def resolve(_pending_ask, _answer, _opts), do: {:error, :invalid_pending_ask}

  def sync_message_id(bot_id, chat_id, old_message_id, new_message_id)
      when is_binary(bot_id) and is_integer(chat_id) and is_integer(old_message_id) and
             is_integer(new_message_id) do
    {count, _rows} =
      from(p in PendingAsk,
        where: p.bot_id == ^bot_id and p.chat_id == ^chat_id and p.message_id == ^old_message_id
      )
      |> Repo.update_all(set: [message_id: new_message_id, updated_at: DateTime.utc_now()])

    count
  end

  def sync_message_id(_bot_id, _chat_id, _old_message_id, _new_message_id), do: 0
end
