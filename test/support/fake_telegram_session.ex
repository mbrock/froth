defmodule Froth.FakeTelegramSession do
  @moduledoc """
  Test double for `Froth.Telegram.Session` that registers itself under
  the standard session via-tuple so `Froth.Telegram.Bot` + tool
  execution can talk to it without any mocking.

  On each `GenServer.call({:call, request})` it echoes
  `{:telegram_call, request}` to the owning test pid, then:

    * For `sendMessage`, it assigns a VM-unique temp message id,
      enqueues a `:send_success` for itself to process asynchronously
      (broadcasting `updateMessageSendSucceeded` and pinging the test
      with `{:message_send_succeeded, old_id, new_id, chat_id, text}`),
      and replies to the caller with `{:ok, %{"id" => temp_id}}`.

    * For other TDLib request types (`answerCallbackQuery`,
      `editMessageText`, `parseTextEntities`, everything else) it
      returns a minimal success reply.

  Also opts itself into the test's `Ecto` sandbox allowance chain so
  the bot (which will `Froth.Repo.allow(Session.via(session_id))`) has
  a valid parent to hang off when the Repo is running under
  `Ecto.Adapters.SQL.Sandbox`.
  """

  use GenServer

  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Froth.Telegram.Session.via(session_id))
  end

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    Froth.Repo.allow(test_pid, "fake telegram session")

    {:ok,
     %{
       request_handler: Keyword.get(opts, :request_handler),
       session_id: Keyword.fetch!(opts, :session_id),
       test_pid: test_pid
     }}
  end

  @impl true
  def handle_call({:call, request}, _from, state) do
    send(state.test_pid, {:telegram_call, request})

    case custom_reply(state.request_handler, request) do
      {:reply, reply} ->
        {:reply, reply, state}

      :default ->
        case request["@type"] do
          "sendMessage" ->
            temp_id = 1_000_000 + System.unique_integer([:positive])
            final_id = temp_id + 10_000
            chat_id = request["chat_id"]
            text = get_in(request, ["input_message_content", "text", "text"]) || ""
            send(self(), {:send_success, temp_id, final_id, chat_id, text})

            {:reply, {:ok, %{"id" => temp_id, "chat_id" => chat_id}}, state}

          "answerCallbackQuery" ->
            {:reply, {:ok, %{}}, state}

          "editMessageText" ->
            {:reply, {:ok, %{}}, state}

          "parseTextEntities" ->
            {:reply,
             {:ok, %{"@type" => "formattedText", "text" => request["text"], "entities" => []}},
             state}

          _ ->
            {:reply, {:ok, %{}}, state}
        end
    end
  end

  @impl true
  def handle_cast({:send, request}, state) do
    send(state.test_pid, {:telegram_send, request})
    {:noreply, state}
  end

  @impl true
  def handle_info({:send_success, old_id, new_id, chat_id, text}, state) do
    Phoenix.PubSub.broadcast(
      Froth.PubSub,
      Froth.Telegram.Session.topic(state.session_id),
      {:telegram_update,
       %{
         "@type" => "updateMessageSendSucceeded",
         "old_message_id" => old_id,
         "message" => %{"id" => new_id, "chat_id" => chat_id}
       }}
    )

    send(state.test_pid, {:message_send_succeeded, old_id, new_id, chat_id, text})
    {:noreply, state}
  end

  defp custom_reply(handler, request) when is_function(handler, 1) do
    case handler.(request) do
      :default -> :default
      reply -> {:reply, reply}
    end
  end

  defp custom_reply(_handler, _request), do: :default
end
