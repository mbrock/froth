defmodule Froth.Telegram.Cnode do
  @moduledoc """
  Shared TDLib C node owner for all Telegram sessions.

  The external cnode process is started once and multiplexes all TDLib sessions
  internally via TDLib `client_id`s.
  """

  use GenServer

  alias Froth.Telemetry.Span

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def register_session(session_id, pid \\ self())
      when is_binary(session_id) and is_pid(pid) do
    call_safe({:register_session, session_id, pid})
  end

  def unregister_session(session_id, pid \\ self())
      when is_binary(session_id) and is_pid(pid) do
    case Process.whereis(@name) do
      nil -> :ok
      _ -> GenServer.cast(@name, {:unregister_session, session_id, pid})
    end
  end

  def send(session_id, json) when is_binary(session_id) and is_binary(json) do
    call_safe({:send, session_id, json})
  end

  def connected? do
    call_safe(:connected?)
  end

  def tgcalls_status(timeout \\ 2_000) when is_integer(timeout) and timeout > 0 do
    call_safe({:tgcalls_status, timeout}, timeout + 1_000)
  end

  def start_private_media(call_id, pid \\ self()) when is_integer(call_id) and is_pid(pid) do
    call_safe({:start_private_media, call_id, pid})
  end

  def stop_private_media(call_id) when is_integer(call_id) do
    call_safe({:stop_private_media, call_id})
  end

  def feed_pcm_file(call_id, path) when is_integer(call_id) and is_binary(path) do
    call_safe({:feed_pcm_file, call_id, path})
  end

  def feed_pcm_frame(call_id, pcm_frame) when is_integer(call_id) and is_binary(pcm_frame) do
    call_safe({:feed_pcm_frame, call_id, pcm_frame})
  end

  def subscribe_call_audio(call_id, pid \\ self()) when is_integer(call_id) and is_pid(pid) do
    call_safe({:subscribe_call_audio, call_id, pid})
  end

  def unsubscribe_call_audio(call_id, pid \\ self()) when is_integer(call_id) and is_pid(pid) do
    call_safe({:unsubscribe_call_audio, call_id, pid})
  end

  def start_tgcalls_call(
        call_id,
        session_id,
        version,
        is_outgoing,
        allow_p2p,
        encryption_key,
        servers,
        custom_parameters,
        pid \\ self()
      )
      when is_integer(call_id) and is_binary(session_id) and is_binary(version) and
             is_boolean(is_outgoing) and is_boolean(allow_p2p) and is_binary(encryption_key) and
             is_list(servers) and is_binary(custom_parameters) and is_pid(pid) do
    call_safe(
      {:start_tgcalls_call, call_id, session_id, version, is_outgoing, allow_p2p, encryption_key,
       servers, custom_parameters, pid}
    )
  end

  def start_tgcalls_group_call(group_call_id, session_id, pid \\ self())
      when is_integer(group_call_id) and is_binary(session_id) and is_pid(pid) do
    call_safe({:start_tgcalls_group_call, group_call_id, session_id, pid})
  end

  def set_tgcalls_group_join_response(group_call_id, payload)
      when is_integer(group_call_id) and is_binary(payload) do
    call_safe({:set_tgcalls_group_join_response, group_call_id, payload})
  end

  def stop_tgcalls_group_call(group_call_id) when is_integer(group_call_id) do
    call_safe({:stop_tgcalls_group_call, group_call_id})
  end

  def stop_tgcalls_call(call_id) when is_integer(call_id) do
    call_safe({:stop_tgcalls_call, call_id})
  end

  def receive_tgcalls_signaling_data(call_id, data)
      when is_integer(call_id) and is_binary(data) do
    call_safe({:receive_tgcalls_signaling_data, call_id, data})
  end

  @impl true
  def init([]) do
    if not Node.alive?() do
      Span.execute([:froth, :telegram, :cnode, :no_distribution], nil, %{})
      :ignore
    else
      :net_kernel.monitor_nodes(true)

      state = %{
        cnode_node: derive_cnode_node(),
        server_name: derive_server_name(),
        executable: cnode_executable(),
        port: nil,
        owned?: false,
        connected?: false,
        connect_attempts: 0,
        sessions: %{},
        pending_tgcalls_status: nil
      }

      Process.send_after(self(), :telegram_connect, 0)
      {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.connected? and state.owned? do
      send_to_cnode(state, {:stop})
    end

    if state.port do
      Port.close(state.port)
    end

    :ok
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, {:ok, state.connected?}, state}
  end

  def handle_call({:register_session, session_id, pid}, _from, state) do
    Span.execute([:froth, :telegram, :cnode, :register], nil, %{
      session: session_id,
      pid: pid,
      connected: state.connected?
    })

    state = put_session(state, session_id, pid)

    if state.connected? do
      send_to_cnode(state, {:init, session_id, pid})
    end

    {:reply, {:ok, state.connected?}, state}
  end

  def handle_call({:send, session_id, json}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      :error ->
        Span.execute([:froth, :telegram, :cnode, :unknown_session], nil, %{session: session_id})
        {:reply, {:error, :unknown_session}, state}

      {:ok, _session} ->
        if state.connected? do
          send_to_cnode(state, {:send, session_id, json})
          {:reply, :ok, state}
        else
          Span.execute([:froth, :telegram, :cnode, :not_connected], nil, %{session: session_id})
          {:reply, {:error, :not_connected}, state}
        end
    end
  end

  def handle_call({:tgcalls_status, _timeout}, _from, %{connected?: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:tgcalls_status, _timeout}, _from, %{pending_tgcalls_status: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :status_request_in_flight}, state}
  end

  def handle_call({:tgcalls_status, timeout}, from, state) do
    send_to_cnode(state, {:tgcalls_status, self()})
    timer_ref = Process.send_after(self(), :tgcalls_status_timeout, timeout)
    pending = %{from: from, timer_ref: timer_ref}
    {:noreply, %{state | pending_tgcalls_status: pending}}
  end

  def handle_call({:start_private_media, call_id, pid}, _from, state) do
    relay_media_command(state, {:start_private_media, call_id, pid})
  end

  def handle_call({:stop_private_media, call_id}, _from, state) do
    relay_media_command(state, {:stop_private_media, call_id})
  end

  def handle_call({:feed_pcm_file, call_id, path}, _from, state) do
    relay_media_command(state, {:feed_pcm_file, call_id, path})
  end

  def handle_call({:feed_pcm_frame, call_id, pcm_frame}, _from, state) do
    relay_media_command(state, {:feed_pcm_frame, call_id, pcm_frame})
  end

  def handle_call({:subscribe_call_audio, call_id, pid}, _from, state) do
    relay_media_command(state, {:subscribe_call_audio, call_id, pid})
  end

  def handle_call({:unsubscribe_call_audio, call_id, pid}, _from, state) do
    relay_media_command(state, {:unsubscribe_call_audio, call_id, pid})
  end

  def handle_call(
        {:start_tgcalls_call, call_id, session_id, version, is_outgoing, allow_p2p,
         encryption_key, servers, custom_parameters, pid},
        _from,
        state
      ) do
    relay_media_command(
      state,
      {:start_tgcalls_call, call_id, session_id, version, is_outgoing, allow_p2p, encryption_key,
       servers, custom_parameters, pid}
    )
  end

  def handle_call({:start_tgcalls_group_call, group_call_id, session_id, pid}, _from, state) do
    relay_media_command(state, {:start_tgcalls_group_call, group_call_id, session_id, pid})
  end

  def handle_call({:set_tgcalls_group_join_response, group_call_id, payload}, _from, state) do
    relay_media_command(state, {:set_tgcalls_group_join_response, group_call_id, payload})
  end

  def handle_call({:stop_tgcalls_group_call, group_call_id}, _from, state) do
    relay_media_command(state, {:stop_tgcalls_group_call, group_call_id})
  end

  def handle_call({:stop_tgcalls_call, call_id}, _from, state) do
    relay_media_command(state, {:stop_tgcalls_call, call_id})
  end

  def handle_call({:receive_tgcalls_signaling_data, call_id, data}, _from, state) do
    relay_media_command(state, {:receive_tgcalls_signaling_data, call_id, data})
  end

  @impl true
  def handle_cast({:unregister_session, session_id, pid}, state) do
    Span.execute([:froth, :telegram, :cnode, :unregister], nil, %{session: session_id, pid: pid})
    {state, removed?} = remove_session(state, session_id, pid)

    if removed? and state.connected? do
      send_to_cnode(state, {:stop_session, session_id})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:telegram_connect, %{connected?: true} = state) do
    {:noreply, state}
  end

  def handle_info(:telegram_connect, state) do
    if Node.connect(state.cnode_node) do
      Span.execute([:froth, :telegram, :cnode, :connected], nil, %{node: state.cnode_node})
      state = %{state | connected?: true, connect_attempts: 0}
      {:noreply, reinit_sessions(state)}
    else
      state =
        if is_nil(state.port) do
          Span.execute([:froth, :telegram, :cnode, :launching], nil, %{})
          launch_cnode(state)
        else
          state
        end

      attempt = state.connect_attempts + 1
      delay = min(200 * attempt, 2_000)

      if rem(attempt, 10) == 0 do
        Span.execute([:froth, :telegram, :cnode, :connect_retry], nil, %{attempt: attempt})
      end

      Process.send_after(self(), :telegram_connect, delay)
      {:noreply, %{state | connect_attempts: attempt}}
    end
  end

  def handle_info({:nodeup, node}, state) when node == state.cnode_node do
    if state.connected? do
      {:noreply, state}
    else
      Span.execute([:froth, :telegram, :cnode, :node_up], nil, %{node: node})
      state = %{state | connected?: true, connect_attempts: 0}
      {:noreply, reinit_sessions(state)}
    end
  end

  def handle_info({:nodedown, node}, state) when node == state.cnode_node do
    Span.execute([:froth, :telegram, :cnode, :node_down], nil, %{node: node})
    state = mark_disconnected(state)
    Process.send_after(self(), :telegram_connect, 200)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Span.execute([:froth, :telegram, :cnode, :exited], nil, %{status: status})

    state =
      state
      |> mark_disconnected()
      |> Map.put(:port, nil)
      |> Map.put(:owned?, false)
      |> Map.put(:connect_attempts, 0)

    Process.send_after(self(), :telegram_connect, 2_000)
    {:noreply, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    Span.execute([:froth, :telegram, :cnode, :output], nil, %{data: String.trim_trailing(data)})
    {:noreply, state}
  end

  def handle_info({:tgcalls_status, payload}, %{pending_tgcalls_status: pending} = state)
      when is_binary(payload) and not is_nil(pending) do
    Process.cancel_timer(pending.timer_ref)

    reply =
      case Jason.decode(payload) do
        {:ok, status} -> {:ok, status}
        {:error, _} -> {:ok, payload}
      end

    GenServer.reply(pending.from, reply)
    {:noreply, %{state | pending_tgcalls_status: nil}}
  end

  def handle_info(:tgcalls_status_timeout, %{pending_tgcalls_status: pending} = state)
      when not is_nil(pending) do
    GenServer.reply(pending.from, {:error, :timeout})
    {:noreply, %{state | pending_tgcalls_status: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case find_session_by_ref(state, ref, pid) do
      nil ->
        {:noreply, state}

      session_id ->
        {state, true} = remove_session(state, session_id, pid)

        if state.connected? do
          send_to_cnode(state, {:stop_session, session_id})
        end

        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Span.execute([:froth, :telegram, :cnode, :unexpected], nil, %{message: msg})
    {:noreply, state}
  end

  defp call_safe(request) do
    call_safe(request, 5_000)
  end

  defp call_safe(request, timeout) do
    case Process.whereis(@name) do
      nil ->
        {:error, :cnode_unavailable}

      _pid ->
        try do
          GenServer.call(@name, request, timeout)
        catch
          :exit, _ -> {:error, :cnode_unavailable}
        end
    end
  end

  defp reinit_sessions(state) do
    Span.execute([:froth, :telegram, :cnode, :reinit], nil, %{count: map_size(state.sessions)})

    Enum.each(state.sessions, fn {session_id, %{pid: pid}} ->
      Span.execute([:froth, :telegram, :cnode, :reinit_session], nil, %{
        session: session_id,
        pid: pid
      })

      send_to_cnode(state, {:init, session_id, pid})
      Kernel.send(pid, :telegram_cnode_connected)
    end)

    state
  end

  defp mark_disconnected(state) do
    state = fail_pending_tgcalls_status(state, :not_connected)

    if state.connected? do
      Span.execute([:froth, :telegram, :cnode, :disconnecting], nil, %{
        count: map_size(state.sessions)
      })

      Enum.each(state.sessions, fn {session_id, %{pid: pid}} ->
        Span.execute([:froth, :telegram, :cnode, :disconnect_session], nil, %{
          session: session_id,
          pid: pid
        })

        Kernel.send(pid, :telegram_cnode_disconnected)
      end)
    end

    %{state | connected?: false}
  end

  defp fail_pending_tgcalls_status(%{pending_tgcalls_status: nil} = state, _reason), do: state

  defp fail_pending_tgcalls_status(%{pending_tgcalls_status: pending} = state, reason) do
    Process.cancel_timer(pending.timer_ref)
    GenServer.reply(pending.from, {:error, reason})
    %{state | pending_tgcalls_status: nil}
  end

  defp relay_media_command(%{connected?: false} = state, _command) do
    {:reply, {:error, :not_connected}, state}
  end

  defp relay_media_command(state, command) do
    send_to_cnode(state, command)
    {:reply, :ok, state}
  end

  defp put_session(state, session_id, pid) do
    state =
      case Map.get(state.sessions, session_id) do
        %{ref: old_ref} ->
          Process.demonitor(old_ref, [:flush])
          state

        nil ->
          state
      end

    ref = Process.monitor(pid)
    put_in(state.sessions[session_id], %{pid: pid, ref: ref})
  end

  defp remove_session(state, session_id, pid) do
    case Map.get(state.sessions, session_id) do
      %{pid: ^pid, ref: ref} ->
        Process.demonitor(ref, [:flush])
        {%{state | sessions: Map.delete(state.sessions, session_id)}, true}

      _ ->
        {state, false}
    end
  end

  defp find_session_by_ref(state, ref, pid) do
    Enum.find_value(state.sessions, fn {session_id, session} ->
      if session.ref == ref and session.pid == pid, do: session_id, else: nil
    end)
  end

  defp launch_cnode(state) do
    exe = state.executable

    if not is_binary(exe) or exe == "" or not File.exists?(exe) do
      Span.execute([:froth, :telegram, :cnode, :missing_executable], nil, %{path: exe})
      state
    else
      kill_stale_cnode(state.cnode_node)

      port_opts = [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--node",
          Atom.to_string(state.cnode_node),
          "--cookie",
          Atom.to_string(Node.get_cookie()),
          "--server",
          Atom.to_string(state.server_name),
          "--verbosity",
          "1"
        ]
      ]

      port_opts =
        case cnode_tgcalls_plugin() do
          nil ->
            port_opts

          plugin_path ->
            [{:env, [{~c"FROTH_TGCALLS_PLUGIN", String.to_charlist(plugin_path)}]} | port_opts]
        end

      port =
        Port.open(
          {:spawn_executable, exe},
          port_opts
        )

      %{state | port: port, owned?: true}
    end
  end

  defp send_to_cnode(state, msg) do
    Kernel.send({state.server_name, state.cnode_node}, msg)
  end

  defp cnode_executable do
    shared = Application.get_env(:froth, Froth.Telegram, [])

    case Keyword.get(shared, :cnode_executable) do
      exe when is_binary(exe) and exe != "" ->
        exe

      _ ->
        Application.app_dir(:froth, "priv/native/tdlib_cnode/tdlib_cnode")
    end
  end

  defp derive_cnode_node do
    shared = Application.get_env(:froth, Froth.Telegram, [])

    case Keyword.get(shared, :cnode_node) do
      node when is_atom(node) and not is_nil(node) ->
        node

      node when is_binary(node) and node != "" ->
        String.to_atom(node)

      _ ->
        String.to_atom("tdlib_mux@#{node_host()}")
    end
  end

  defp derive_server_name do
    shared = Application.get_env(:froth, Froth.Telegram, [])

    case Keyword.get(shared, :server_name) do
      name when is_atom(name) and not is_nil(name) ->
        name

      name when is_binary(name) and name != "" ->
        String.to_atom(name)

      _ ->
        :tdlib_mux
    end
  end

  defp cnode_tgcalls_plugin do
    shared = Application.get_env(:froth, Froth.Telegram, [])

    configured =
      case Keyword.get(shared, :tgcalls_plugin) do
        path when is_binary(path) and path != "" -> path
        _ -> nil
      end

    configured || default_tgcalls_plugin_path()
  end

  defp default_tgcalls_plugin_path do
    path = Application.app_dir(:froth, "priv/native/tdlib_cnode/libfroth_tgcalls_register.so")
    if File.exists?(path), do: path, else: nil
  end

  defp kill_stale_cnode(cnode_node) do
    node_str = Atom.to_string(cnode_node)

    case System.cmd("pgrep", ["-f", "--node #{node_str}"], stderr_to_stdout: true) do
      {pids, 0} ->
        pids
        |> String.split("\n", trim: true)
        |> Enum.each(fn pid_str ->
          case Integer.parse(pid_str) do
            {pid, _} ->
              Span.execute([:froth, :telegram, :cnode, :kill_stale], nil, %{
                pid: pid,
                node: node_str
              })

              System.cmd("kill", [pid_str])

            :error ->
              :ok
          end
        end)

        Process.sleep(200)

      _ ->
        :ok
    end
  end

  defp node_host do
    Node.self()
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> case do
      [_, host] -> host
      [_] -> "localhost"
    end
  end
end
