defmodule Froth.Telegram.Session do
  @moduledoc """
  Per-session TDLib bridge GenServer.

  Each session owns request/response tracking and auth flow state.
  All sessions share one TDLib C node process managed by `Froth.Telegram.Cnode`.
  """

  use GenServer

  require Logger
  alias Froth.Telegram.Calls

  def start_link(config) when is_map(config) do
    id = Map.fetch!(config, :id)
    GenServer.start_link(__MODULE__, config, name: via(id))
  end

  def via(id), do: {:via, Registry, {Froth.Telegram.Registry, id}}

  def topic(id), do: "telegram:#{id}"

  @impl true
  def init(config) do
    id = Map.fetch!(config, :id)

    if not Node.alive?() do
      Logger.warning(event: :no_distribution, session: id)
      :ignore
    else
      {tgcalls_sink_pid, tgcalls_sink_ref} = start_tgcalls_sink()

      state = %{
        id: id,
        config: config,
        connected?: false,
        pending: %{},
        tgcalls_sink_pid: tgcalls_sink_pid,
        tgcalls_sink_ref: tgcalls_sink_ref
      }

      case Froth.Telegram.Cnode.register_session(id, self()) do
        {:ok, connected?} ->
          Logger.info(event: :registered, session: id, connected: connected?)
          state = %{state | connected?: connected?}

          if connected? do
            send(self(), :telegram_sync_auth_state)
          end

          {:ok, state}

        {:error, reason} ->
          Logger.error(event: :register_failed, session: id, reason: reason)
          {:ok, state}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    Froth.Telegram.Cnode.unregister_session(state.id, self())

    if is_pid(state.tgcalls_sink_pid) do
      Process.demonitor(state.tgcalls_sink_ref, [:flush])
      Process.exit(state.tgcalls_sink_pid, :normal)
    end

    :ok
  end

  @impl true
  def handle_call({:call, request}, from, state) do
    if not state.connected? do
      {:reply, {:error, :not_connected}, state}
    else
      {extra, json} = encode_with_extra(request)

      case send_json(json, state.id) do
        :ok ->
          {:noreply, %{state | pending: Map.put(state.pending, extra, from)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_cast({:send, request}, state) do
    if state.connected? do
      request
      |> encode_request()
      |> send_json(state.id)
      |> maybe_log_send_error(state.id)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:tdjson, json}, state) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"@extra" => extra} = decoded} ->
        state = maybe_handle_auth(decoded, state)
        maybe_route_tgcalls_update(state, decoded)

        case Map.pop(state.pending, extra) do
          {nil, pending} ->
            broadcast(state.id, decoded)
            {:noreply, %{state | pending: pending}}

          {from, pending} ->
            GenServer.reply(from, {:ok, decoded})
            {:noreply, %{state | pending: pending}}
        end

      {:ok, decoded} ->
        state = maybe_handle_auth(decoded, state)
        maybe_route_tgcalls_update(state, decoded)
        broadcast(state.id, decoded)
        {:noreply, state}

      {:error, _} ->
        broadcast(state.id, %{"raw" => json})
        {:noreply, state}
    end
  end

  def handle_info(:telegram_sync_auth_state, state) do
    Logger.info(event: :sync_auth, session: state.id)

    %{"@type" => "getAuthorizationState"}
    |> encode_request()
    |> send_json(state.id)
    |> maybe_log_send_error(state.id)

    {:noreply, state}
  end

  def handle_info(:telegram_cnode_connected, %{connected?: true} = state) do
    Logger.debug(event: :already_connected, session: state.id)
    {:noreply, state}
  end

  def handle_info(:telegram_cnode_connected, state) do
    Logger.info(event: :connected, session: state.id)
    send(self(), :telegram_sync_auth_state)
    {:noreply, %{state | connected?: true}}
  end

  def handle_info(:telegram_cnode_disconnected, state) do
    Logger.warning(event: :disconnected, session: state.id)
    {:noreply, %{state | connected?: false}}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{tgcalls_sink_pid: pid, tgcalls_sink_ref: ref} = state
      ) do
    {tgcalls_sink_pid, tgcalls_sink_ref} = start_tgcalls_sink()

    Logger.warning(event: :tgcalls_sink_restarted, session: state.id)

    {:noreply, %{state | tgcalls_sink_pid: tgcalls_sink_pid, tgcalls_sink_ref: tgcalls_sink_ref}}
  end

  def handle_info(msg, state) do
    Logger.debug(event: :unexpected, session: state.id, message: msg)
    {:noreply, state}
  end

  defp maybe_handle_auth(
         %{"@type" => "updateAuthorizationState", "authorization_state" => auth},
         state
       ) do
    handle_auth_state(auth, state)
  end

  defp maybe_handle_auth(_decoded, state), do: state

  defp maybe_route_tgcalls_update(state, decoded) when is_map(decoded) do
    sink_pid =
      if is_pid(state.tgcalls_sink_pid) and Process.alive?(state.tgcalls_sink_pid) do
        state.tgcalls_sink_pid
      else
        self()
      end

    case Calls.route_tgcalls_update(state.id, decoded, pid: sink_pid) do
      :ok ->
        :ok

      :ignore ->
        :ok

      {:error, :call_not_ready} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          event: :tgcalls_route_failed,
          session: state.id,
          update_type: Map.get(decoded, "@type"),
          reason: reason
        )
    end
  end

  defp maybe_route_tgcalls_update(_state, _decoded), do: :ok

  defp handle_auth_state(%{"@type" => "authorizationStateWaitTdlibParameters"}, state) do
    config = state.config

    params = %{
      "@type" => "setTdlibParameters",
      "use_test_dc" => false,
      "database_directory" => config.database_dir,
      "files_directory" => config.files_dir,
      "database_encryption_key" => "",
      "use_file_database" => true,
      "use_chat_info_database" => true,
      "use_message_database" => true,
      "use_secret_chats" => false,
      "api_id" => config.api_id,
      "api_hash" => config.api_hash,
      "system_language_code" => "en",
      "device_model" => "froth",
      "system_version" => "linux",
      "application_version" => "0.1.0"
    }

    Logger.info(event: :set_tdlib_params, session: state.id)
    send_request(state, params)
    state
  end

  defp handle_auth_state(%{"@type" => "authorizationStateWaitEncryptionKey"}, state) do
    Logger.info(event: :check_encryption_key, session: state.id)
    send_request(state, %{"@type" => "checkDatabaseEncryptionKey", "encryption_key" => ""})
    state
  end

  defp handle_auth_state(%{"@type" => "authorizationStateWaitPhoneNumber"}, state) do
    config = state.config

    cond do
      is_binary(config.bot_token) and config.bot_token != "" ->
        Logger.info(event: :auth_bot_token, session: state.id)

        send_request(state, %{
          "@type" => "checkAuthenticationBotToken",
          "token" => config.bot_token
        })

      is_binary(config.phone_number) and config.phone_number != "" ->
        Logger.info(event: :auth_phone, session: state.id)

        send_request(state, %{
          "@type" => "setAuthenticationPhoneNumber",
          "phone_number" => config.phone_number
        })

      true ->
        Logger.error(event: :no_credentials, session: state.id)
    end

    state
  end

  defp handle_auth_state(%{"@type" => "authorizationStateReady"}, state) do
    Logger.info(event: :ready, session: state.id)
    state
  end

  defp handle_auth_state(%{"@type" => type}, state) do
    Logger.debug(event: :auth_state, session: state.id, type: type)
    state
  end

  defp broadcast(id, decoded) do
    Froth.broadcast(topic(id), {:telegram_update, decoded})
  end

  defp send_request(state, request) do
    request
    |> encode_request()
    |> send_json(state.id)
    |> maybe_log_send_error(state.id)
  end

  defp send_json(json, session_id) when is_binary(json) and is_binary(session_id) do
    case Froth.Telegram.Cnode.send(session_id, json) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, :ok} -> :ok
      {:ok, other} -> {:error, other}
    end
  end

  defp maybe_log_send_error(:ok, _session_id), do: :ok

  defp maybe_log_send_error({:error, reason}, session_id) do
    Logger.error(event: :send_failed, session: session_id, reason: reason)
    {:error, reason}
  end

  defp encode_request(request) when is_binary(request), do: request
  defp encode_request(request) when is_map(request), do: Jason.encode!(request)

  defp encode_with_extra(request) when is_map(request) do
    extra = Base.encode64(:erlang.term_to_binary(make_ref()))
    {extra, Jason.encode!(Map.put(request, "@extra", extra))}
  end

  defp start_tgcalls_sink do
    pid = spawn(fn -> tgcalls_sink_loop() end)
    {pid, Process.monitor(pid)}
  end

  defp tgcalls_sink_loop do
    receive do
      _ -> tgcalls_sink_loop()
    end
  end
end
