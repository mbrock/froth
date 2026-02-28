defmodule Froth.Telegram.Sync do
  @moduledoc """
  Live-captures Telegram messages from a session and stores them in the DB.

  Bots can't call getChatHistory or getChats, so we subscribe to PubSub
  and store every updateNewMessage as it arrives.

  Started automatically for each enabled session. Can also be started manually:

      Froth.Telegram.Sync.start_link("charlie")
  """

  use GenServer

  alias Froth.Telemetry.Span
  alias Froth.Telegram
  alias Froth.Telegram.Message
  alias Froth.Repo

  @history_limit 100

  # --- Backfill (user accounts only, not bots) ---

  @doc """
  Backfill all messages from all chats visible to a user session.
  Bots cannot use this — use a user account session.
  """
  def backfill(session_id, opts \\ []) do
    chat_limit = Keyword.get(opts, :chat_limit, 200)

    Span.execute([:froth, :telegram, :sync, :backfill_start], nil, %{session_id: session_id})

    {:ok, chats} =
      Telegram.call(session_id, %{
        "@type" => "getChats",
        "chat_list" => %{"@type" => "chatListMain"},
        "limit" => chat_limit
      })

    chat_ids = chats["chat_ids"] || []
    Span.execute([:froth, :telegram, :sync, :backfill_chats], nil, %{count: length(chat_ids)})

    total =
      Enum.reduce(chat_ids, 0, fn chat_id, acc ->
        count = backfill_chat(session_id, chat_id)
        acc + count
      end)

    Span.execute([:froth, :telegram, :sync, :backfill_done], nil, %{
      chats: length(chat_ids),
      messages: total
    })

    {:ok, %{chats: length(chat_ids), messages: total}}
  end

  @doc """
  Backfill a single chat fully. Keeps re-fetching until TDLib
  returns no new messages (each round may pull more from the server).
  """
  def backfill_chat(session_id, chat_id) do
    backfill_chat_loop(session_id, chat_id, 0)
  end

  defp backfill_chat_loop(session_id, chat_id, grand_total) do
    count = fetch_history(session_id, chat_id, 0, 0)

    if count > 0 do
      Span.execute([:froth, :telegram, :sync, :backfill_round], nil, %{
        chat_id: chat_id,
        count: count
      })

      backfill_chat_loop(session_id, chat_id, grand_total + count)
    else
      if grand_total > 0 do
        Span.execute([:froth, :telegram, :sync, :backfill_chat_done], nil, %{
          chat_id: chat_id,
          total: grand_total
        })
      end

      grand_total
    end
  end

  defp fetch_history(session_id, chat_id, from_message_id, total) do
    case Telegram.call(
           session_id,
           %{
             "@type" => "getChatHistory",
             "chat_id" => chat_id,
             "from_message_id" => from_message_id,
             "offset" => 0,
             "limit" => @history_limit,
             "only_local" => false
           },
           60_000
         ) do
      {:ok, %{"messages" => messages}} when is_list(messages) and messages != [] ->
        stored = store_batch(session_id, messages)
        oldest_id = messages |> List.last() |> Map.fetch!("id")
        new_total = total + stored

        if length(messages) < @history_limit do
          log_backfill(chat_id, new_total)
          new_total
        else
          fetch_history(session_id, chat_id, oldest_id, new_total)
        end

      {:ok, %{"messages" => _}} ->
        log_backfill(chat_id, total)
        total

      {:ok, %{"@type" => "error", "message" => msg}} ->
        Span.execute([:froth, :telegram, :sync, :backfill_error], nil, %{
          chat_id: chat_id,
          error: msg
        })

        total

      other ->
        Span.execute([:froth, :telegram, :sync, :backfill_error], nil, %{
          chat_id: chat_id,
          response: other
        })

        total
    end
  end

  defp store_batch(session_id, messages) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.count(messages, fn msg ->
      case store_message_raw(session_id, msg, now) do
        {:ok, :inserted} -> true
        _ -> false
      end
    end)
  end

  defp log_backfill(chat_id, 0),
    do: Span.execute([:froth, :telegram, :sync, :backfill_empty], nil, %{chat_id: chat_id})

  defp log_backfill(chat_id, n),
    do:
      Span.execute([:froth, :telegram, :sync, :backfill_stored], nil, %{
        chat_id: chat_id,
        count: n
      })

  # --- Live capture GenServer ---

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {Froth.Telegram.Registry, {:sync, session_id}}}

  @impl true
  def init(session_id) do
    :ok = Phoenix.PubSub.subscribe(Froth.PubSub, Froth.Telegram.Session.topic(session_id))
    Span.execute([:froth, :telegram, :sync, :listening], nil, %{session_id: session_id})
    {:ok, %{session_id: session_id, count: 0}}
  end

  @impl true
  def handle_info({:telegram_update, %{"@type" => "updateNewMessage", "message" => msg}}, state) do
    case store_message(state.session_id, msg) do
      {:ok, :inserted} ->
        Froth.Analyzer.Discovery.discover_message(msg["chat_id"], msg["id"], msg)
        {:noreply, %{state | count: state.count + 1}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:telegram_update, %{"@type" => "updateMessageSendSucceeded", "message" => msg}},
        state
      ) do
    case store_message(state.session_id, msg) do
      {:ok, :inserted} ->
        {:noreply, %{state | count: state.count + 1}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:telegram_update, _}, state), do: {:noreply, state}

  defp store_message(session_id, msg) do
    chat_id = msg["chat_id"]
    message_id = msg["id"]

    if is_nil(chat_id) or is_nil(message_id) do
      {:ok, :skipped}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      store_message_raw(session_id, msg, now)
    end
  end

  defp store_message_raw(session_id, msg, now) do
    result =
      %Message{}
      |> Message.changeset(%{
        telegram_session_id: session_id,
        chat_id: msg["chat_id"],
        message_id: msg["id"],
        sender_id: Message.extract_sender_id(msg),
        date: msg["date"],
        raw: msg
      })
      |> Ecto.Changeset.put_change(:inserted_at, now)
      |> Repo.insert(on_conflict: :nothing)

    case result do
      {:ok, %{id: nil}} ->
        {:ok, :duplicate}

      {:ok, _} ->
        {:ok, :inserted}

      {:error, cs} ->
        Span.execute(
          [:froth, :telegram, :sync, :store_failed],
          nil,
          %{chat_id: msg["chat_id"], message_id: msg["id"], errors: cs.errors}
        )

        {:error, cs}
    end
  end
end
