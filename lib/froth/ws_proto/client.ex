defmodule WsProto.Client do
  @moduledoc """
  WebSocket client GenServer built on `WsProto`.

  Connects via TLS, performs the HTTP upgrade, then:
  - Receives data async (`active: :once`)
  - Maintains an explicit send queue (`:queue` in state, not the mailbox)
  - Writes to the socket from a dedicated sender process so the
    main loop is never blocked by TLS backpressure
  - Delivers decoded frames to the caller as `{:ws, pid, event}` messages

  ## Usage

      {:ok, pid} = WsProto.Client.start_link("wss://host/path",
        headers: [{"authorization", "Bearer ..."}],
        caller: self()
      )

      WsProto.Client.send(pid, {:text, payload})

  The caller receives:

      {:ws, pid, :connected}
      {:ws, pid, {:text, data}}
      {:ws, pid, {:binary, data}}
      {:ws, pid, {:ping, data}}
      {:ws, pid, {:close, code, reason}}
      {:ws, pid, {:error, reason}}

  ## Why this exists

  The standard Elixir WebSocket clients (Fresh/Mint) handle sending
  synchronously inside the process that also receives. When the remote
  end is slow to ACK (TLS backpressure), `:ssl.send/2` blocks, and
  the process can't read its mailbox. Incoming messages pile up
  invisibly. We saw the Qwen ASR process stuck for 5-10 seconds at a
  time on `:tls_sender.call/2` while 100+ audio frames queued in its
  BEAM mailbox — completely invisible to application code.

  This module fixes that by separating concerns:

  1. The GenServer receives data and manages state — never blocks.
  2. A linked sender process does the blocking `:ssl.send` calls.
  3. The send queue is an explicit `:queue` data structure in GenServer
     state, with a counter, so you can always observe how backed up
     things are.
  """

  use GenServer

  require Logger

  defstruct [
    :ws,
    :socket,
    :caller,
    :sender,
    :send_started_at,
    send_queue: :queue.new(),
    send_queue_len: 0,
    sending?: false,
    stats: %{sent: 0, received: 0, send_us_total: 0}
  ]

  def start_link(url, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())
    GenServer.start_link(__MODULE__, {url, caller, opts})
  end

  def send(pid, frame) do
    GenServer.cast(pid, {:send, frame})
  end

  def send_many(pid, frames) when is_list(frames) do
    GenServer.cast(pid, {:send_many, frames})
  end

  def queue_info(pid) do
    GenServer.call(pid, :queue_info)
  end

  # -- Init: TLS connect + WS upgrade ----------------------------------------
  #
  # We open the socket in passive mode (`active: false`) just long
  # enough to send the HTTP upgrade request synchronously — this is
  # the one blocking send we do from the GenServer, and it's tiny
  # (a few hundred bytes of HTTP headers).
  #
  # Immediately after, we flip to `active: :once` so the BEAM
  # delivers the next chunk of TLS data as a message to our mailbox.
  # We re-arm `active: :once` after every received message. This is
  # the standard flow-control pattern: the process is never flooded
  # with data faster than it can handle, and it never needs to poll.

  @impl true
  def init({url, caller, opts}) do
    uri = URI.parse(url)
    headers = Keyword.get(opts, :headers, [])
    host = String.to_charlist(uri.host)
    port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)

    transport = if uri.scheme == "wss", do: :ssl, else: :gen_tcp

    connect_opts =
      [:binary, active: false, packet: :raw] ++
        if transport == :ssl do
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: host,
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        else
          []
        end

    Logger.info(event: :ws_connecting, host: uri.host, port: port, transport: transport)

    case transport.connect(host, port, connect_opts, 10_000) do
      {:ok, socket} ->
        ws = WsProto.new(uri)
        {ws, upgrade_bytes} = WsProto.upgrade(ws, headers)
        transport.send(socket, upgrade_bytes)
        Logger.info(event: :ws_upgrade_sent, host: uri.host)
        set_active(transport, socket)

        sender = spawn_sender(transport, socket)

        {:ok,
         %__MODULE__{
           ws: ws,
           socket: {transport, socket},
           caller: caller,
           sender: sender
         }}

      {:error, reason} ->
        Logger.error(event: :ws_connect_failed, host: uri.host, reason: inspect(reason))
        {:stop, reason}
    end
  end

  # -- Incoming TLS data -----------------------------------------------------
  #
  # `{:ssl, socket, data}` arrives because we set `active: :once`.
  # We immediately re-arm for the next chunk, then feed the raw bytes
  # into `WsProto.receive/2` which decodes frames and returns events.
  #
  # Pings get an automatic pong enqueued. Close frames are echoed
  # back per the RFC. Everything else is forwarded to the caller.

  @impl true
  def handle_info({proto, _sock, data}, state) when proto in [:ssl, :tcp] do
    {transport, raw} = state.socket
    set_active(transport, raw)

    Logger.debug(event: :ws_raw_recv, bytes: byte_size(data), ws_state: state.ws.state)
    {ws, events} = WsProto.receive(state.ws, data)
    state = %{state | ws: ws}

    state =
      Enum.reduce(events, state, fn
        :upgraded, st ->
          Logger.info(event: :ws_connected, queue: st.send_queue_len)
          notify(st, :connected)
          st

        {:error, reason}, st ->
          Logger.error(event: :ws_upgrade_failed, reason: inspect(reason))
          notify(st, {:error, reason})
          st

        {:ping, payload}, st ->
          Logger.debug(event: :ws_ping, bytes: byte_size(payload))
          enqueue(st, {:pong, payload})

        {:close, code, reason}, st ->
          Logger.info(event: :ws_recv_close, code: code, reason: reason)
          notify(st, {:close, code, reason})
          enqueue(st, {:close, code, reason})

        {:text, _text} = frame, st ->
          st = update_in(st.stats.received, &(&1 + 1))
          notify(st, frame)
          st

        {:binary, _bin} = frame, st ->
          st = update_in(st.stats.received, &(&1 + 1))
          notify(st, frame)
          st

        frame, st ->
          notify(st, frame)
          st
      end)

    {:noreply, state}
  end

  def handle_info({closed, _sock}, state) when closed in [:ssl_closed, :tcp_closed] do
    Logger.info(event: :ws_closed, stats: state.stats)
    notify(state, {:error, :closed})
    {:stop, :normal, state}
  end

  def handle_info({error, _sock, reason}, state) when error in [:ssl_error, :tcp_error] do
    Logger.error(event: :ws_socket_error, reason: inspect(reason), stats: state.stats)
    notify(state, {:error, reason})
    {:stop, reason, state}
  end

  # -- Sender acknowledgement -------------------------------------------------
  #
  # The sender process reports back after each write completes.
  # We match on the ref to ensure we're handling the right one,
  # then try to flush the next frame from the queue.

  def handle_info({:send_done, ref, :ok}, %{sending?: {true, ref}} = state) do
    send_us = System.monotonic_time(:microsecond) - state.send_started_at
    state = %{state | sending?: false}
    state = update_in(state.stats.sent, &(&1 + 1))
    state = update_in(state.stats.send_us_total, &(&1 + send_us))

    if send_us > 100_000 or state.send_queue_len > 0 do
      Logger.info(
        event: :ws_send_done,
        send_ms: div(send_us, 1000),
        queue: state.send_queue_len,
        sent: state.stats.sent
      )
    end

    {:noreply, maybe_flush(state)}
  end

  def handle_info({:send_done, ref, {:error, reason}}, %{sending?: {true, ref}} = state) do
    Logger.error(event: :ws_send_failed, reason: inspect(reason), stats: state.stats)
    notify(state, {:error, {:send_failed, reason}})
    {:stop, reason, state}
  end

  def handle_info(msg, state) do
    Logger.debug("WsProto.Client unhandled: #{inspect(msg, limit: 5)}")
    {:noreply, state}
  end

  # -- Casts: enqueue frames --------------------------------------------------

  @impl true
  def handle_cast({:send, frame}, state) do
    {:noreply, state |> enqueue(frame) |> maybe_flush()}
  end

  def handle_cast({:send_many, frames}, state) do
    state = Enum.reduce(frames, state, &enqueue(&2, &1))
    {:noreply, maybe_flush(state)}
  end

  # -- Calls ------------------------------------------------------------------

  @impl true
  def handle_call(:queue_info, _from, state) do
    {:reply, %{len: state.send_queue_len, sending: state.sending? != false}, state}
  end

  # -- Send queue --------------------------------------------------------------
  #
  # The queue is a plain Erlang `:queue` (a pair of lists, O(1)
  # amortized enqueue/dequeue). We also keep a counter so you don't
  # have to traverse the queue to know its size.
  #
  # `enqueue/2` encodes the frame via `WsProto.send/2` (which does
  # masking, framing, etc.) and appends the resulting iodata to the
  # queue. The raw bytes are ready to go — no further encoding needed
  # at flush time.
  #
  # `maybe_flush/1` pops one item and hands it to the sender process,
  # but only if the sender isn't already busy. This serializes writes
  # (TLS doesn't support concurrent writes on the same socket) while
  # keeping the GenServer free to process other messages.

  defp enqueue(state, frame) do
    {ws, iodata} = WsProto.send(state.ws, frame)

    %{
      state
      | ws: ws,
        send_queue: :queue.in(iodata, state.send_queue),
        send_queue_len: state.send_queue_len + 1
    }
  end

  defp maybe_flush(%{sending?: false} = state) do
    case :queue.out(state.send_queue) do
      {{:value, iodata}, rest} ->
        ref = make_ref()
        Kernel.send(state.sender, {:send, ref, iodata, self()})

        %{
          state
          | send_queue: rest,
            send_queue_len: state.send_queue_len - 1,
            sending?: {true, ref},
            send_started_at: System.monotonic_time(:microsecond)
        }

      {:empty, _} ->
        state
    end
  end

  defp maybe_flush(state), do: state

  defp notify(%{caller: caller} = _state, event) do
    Kernel.send(caller, {:ws, self(), event})
  end

  defp set_active(:ssl, socket), do: :ssl.setopts(socket, active: :once)
  defp set_active(:gen_tcp, socket), do: :inet.setopts(socket, active: :once)

  # -- Sender process ----------------------------------------------------------
  #
  # A bare `spawn_link`'d process whose only job is to call
  # `transport.send(socket, iodata)` — the potentially-blocking TLS
  # write. It sends `{:send_done, ref, result}` back so the
  # GenServer knows when the write finished and can flush the next
  # frame.
  #
  # Because this is a separate process, the GenServer's mailbox stays
  # responsive even when TLS backpressure makes a write take seconds.
  # That was the whole problem with Fresh: the `gen_statem` did the
  # write inline, so its mailbox filled up while it was stuck in
  # `:ssl.send/2`.

  defp spawn_sender(transport, socket) do
    spawn_link(fn -> sender_loop(transport, socket) end)
  end

  defp sender_loop(transport, socket) do
    receive do
      {:send, ref, iodata, reply_to} ->
        result = transport.send(socket, iodata)
        Kernel.send(reply_to, {:send_done, ref, result})
        sender_loop(transport, socket)
    end
  end
end
