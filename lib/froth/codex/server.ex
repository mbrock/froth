defmodule Froth.Codex.Server do
  @moduledoc """
  Owns the single Codex app-server transport used by a Froth node.

  Codex app-server multiplexes many threads over one initialized connection.
  Thread observers call `client/0` to lazily boot that connection and all
  notifications are broadcast on the shared `codex:wire` PubSub topic.
  """

  use GenServer

  @client Froth.Codex.Client
  @topic "codex:wire"
  @request_timeout_ms 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec client() :: {:ok, pid()} | {:error, term()}
  def client do
    GenServer.call(__MODULE__, :client, @request_timeout_ms + 5_000)
  end

  def topic, do: @topic

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{client_pid: nil, client_ref: nil, error: nil}}
  end

  @impl true
  def handle_call(:client, _from, %{client_pid: pid} = state)
      when is_pid(pid) do
    if Process.alive?(pid) do
      {:reply, {:ok, pid}, state}
    else
      boot_client(%{state | client_pid: nil, client_ref: nil})
    end
  end

  def handle_call(:client, _from, state), do: boot_client(state)

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{client_ref: ref, client_pid: pid} = state
      ) do
    Phoenix.PubSub.broadcast(
      Froth.PubSub,
      @topic,
      {:codex, :protocol_error, {:shared_server_exited, reason}}
    )

    {:noreply, %{state | client_pid: nil, client_ref: nil, error: reason}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.client_pid) and Process.alive?(state.client_pid) do
      Froth.Codex.stop(state.client_pid)
    end

    :ok
  end

  defp boot_client(state) do
    opts = [
      name: @client,
      topic: @topic,
      cwd: File.cwd!(),
      request_timeout: @request_timeout_ms
    ]

    case Froth.Codex.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)

        case Froth.Codex.handshake(pid, client_info()) do
          {:ok, _result} ->
            ref = Process.monitor(pid)
            state = %{state | client_pid: pid, client_ref: ref, error: nil}
            {:reply, {:ok, pid}, state}

          {:error, reason} ->
            if Process.alive?(pid), do: Froth.Codex.stop(pid)
            {:reply, {:error, reason}, %{state | error: reason}}
        end

      {:error, {:already_started, pid}} ->
        ref = Process.monitor(pid)

        {:reply, {:ok, pid},
         %{state | client_pid: pid, client_ref: ref, error: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  defp client_info do
    %{
      name: "froth_codex",
      title: "Froth Codex",
      version: to_string(Application.spec(:froth, :vsn) || "dev")
    }
  end
end
