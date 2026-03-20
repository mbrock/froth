defmodule Froth.Browser.CDP do
  @moduledoc false

  use GenServer

  alias Froth.Telemetry.Span

  @default_timeout_ms 10_000

  def start_link(opts) when is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)
    websocket_url = Keyword.fetch!(opts, :websocket_url)
    GenServer.start_link(__MODULE__, %{owner: owner, websocket_url: websocket_url})
  end

  def await_connected(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    GenServer.call(pid, :await_connected, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :cdp_not_running}
    :exit, reason -> {:error, reason}
  end

  def command(pid, method, params \\ %{}, opts \\ [])
      when is_pid(pid) and is_binary(method) and is_map(params) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    GenServer.call(pid, {:command, method, params, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :cdp_not_running}
    :exit, reason -> {:error, reason}
  end

  def close(pid) when is_pid(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(%{owner: owner, websocket_url: websocket_url}) do
    Process.flag(:trap_exit, true)

    case WsProto.Client.start_link(websocket_url, caller: self()) do
      {:ok, ws_pid} ->
        {:ok,
         %{
           owner: owner,
           ws_pid: ws_pid,
           connected?: false,
           waiters: [],
           next_id: 1,
           pending: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:await_connected, from, %{connected?: false} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await_connected, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:command, _method, _params, _opts}, _from, %{connected?: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:command, method, params, opts}, from, state) do
    id = state.next_id
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    session_id = Keyword.get(opts, :session_id)

    payload =
      %{"id" => id, "method" => method, "params" => params}
      |> maybe_put_session_id(session_id)

    Span.execute([:froth, :browser, :cdp, :request], nil, %{
      method: method,
      session_id: session_id,
      id: id
    })

    WsProto.Client.send(state.ws_pid, {:text, Jason.encode!(payload)})

    timer = Process.send_after(self(), {:command_timeout, id}, timeout_ms)

    pending =
      Map.put(state.pending, id, %{
        from: from,
        method: method,
        timer: timer
      })

    {:noreply, %{state | next_id: id + 1, pending: pending}}
  end

  @impl true
  def handle_info({:ws, _ws_pid, :connected}, state) do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    send(state.owner, {:browser_cdp_connected, self()})
    {:noreply, %{state | connected?: true, waiters: []}}
  end

  def handle_info({:ws, _ws_pid, {:text, payload}}, state) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id} = response} ->
        {:noreply, reply_pending(state, id, response)}

      {:ok, %{"method" => method} = event} ->
        Span.execute([:froth, :browser, :cdp, :event], nil, %{
          method: method,
          session_id: event["sessionId"]
        })

        send(state.owner, {:browser_cdp_event, self(), event})
        {:noreply, state}

      {:ok, _other} ->
        {:noreply, state}

      {:error, reason} ->
        send(state.owner, {:browser_cdp_error, self(), {:invalid_json, reason}})
        {:noreply, state}
    end
  end

  def handle_info({:ws, _ws_pid, {:error, reason}}, state) do
    send(state.owner, {:browser_cdp_error, self(), reason})
    {:stop, reason, state}
  end

  def handle_info({:ws, _ws_pid, {:close, code, reason}}, state) do
    send(state.owner, {:browser_cdp_closed, self(), {code, reason}})
    {:stop, :normal, state}
  end

  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:EXIT, ws_pid, reason}, %{ws_pid: ws_pid} = state) do
    send(state.owner, {:browser_cdp_error, self(), {:ws_exit, reason}})
    {:stop, reason, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))

    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    :ok
  end

  defp reply_pending(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        %{state | pending: pending}

      {%{from: from, timer: timer, method: method}, pending} ->
        Process.cancel_timer(timer)

        reply =
          case response do
            %{"error" => error} -> {:error, %{method: method, error: error}}
            %{"result" => result} -> {:ok, result}
            _ -> {:error, :invalid_response}
          end

        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp maybe_put_session_id(payload, nil), do: payload
  defp maybe_put_session_id(payload, session_id), do: Map.put(payload, "sessionId", session_id)
end
