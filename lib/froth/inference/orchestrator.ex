defmodule Froth.Inference.Orchestrator do
  @moduledoc """
  Runtime coordinator for inference session scheduling and tool-loop control.

  This module is transport-agnostic. It does not parse Telegram updates; callers
  invoke explicit actions such as starting inference sessions and resolving tools.
  """

  use GenServer
  require Logger

  alias Froth.Inference.Recovery
  alias Froth.Inference.RuntimeConfig
  alias Froth.Inference.SessionLookup
  alias Froth.Inference.SessionScheduler
  alias Froth.Inference.ToolSteps

  @spec tool_steps_for_chat(integer(), integer() | keyword()) :: [map()]
  defdelegate tool_steps_for_chat(chat_id, limit_or_opts \\ 20), to: ToolSteps

  def start_inference_session(server, msg) when is_pid(server) and is_map(msg) do
    GenServer.cast(server, {:start_inference_session, msg})
  end

  def resolve_tool(server, ref, action)
      when is_pid(server) and is_binary(ref) and is_binary(action) do
    GenServer.cast(server, {:resolve_tool, ref, action})
  end

  def continue_loop(server, inference_session_id)
      when is_pid(server) and is_integer(inference_session_id) do
    GenServer.cast(server, {:continue_loop, inference_session_id})
  end

  def stop_loop(server, inference_session_id)
      when is_pid(server) and is_integer(inference_session_id) do
    GenServer.cast(server, {:stop_loop, inference_session_id})
  end

  def auto_approve(server, ref) when is_pid(server) and is_binary(ref) do
    GenServer.cast(server, {:auto_approve, ref})
  end

  def abort_tool(server, ref) when is_pid(server) and is_binary(ref) do
    GenServer.cast(server, {:abort_tool, ref})
  end

  def start_link(opts \\ [])

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    config = RuntimeConfig.build(opts)
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, config)
    else
      GenServer.start_link(__MODULE__, config, name: name)
    end
  end

  @impl true
  def init(config) when is_map(config) do
    :ok = Recovery.resume_on_startup(config.id)
    {:ok, scheduler} = SessionScheduler.start_link(config: config)
    {:ok, %{config: config, scheduler: scheduler}}
  end

  @impl true
  def handle_info({:resume_inference_session, inference_session_id}, state) do
    dispatch_to_inference_session(state, inference_session_id, {:resume, inference_session_id})
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:start_inference_session, msg}, state) when is_map(msg) do
    SessionScheduler.enqueue_mention(state.scheduler, msg)
    {:noreply, state}
  end

  def handle_cast({:resolve_tool, ref, action}, state)
      when is_binary(ref) and is_binary(action) do
    dispatch_by_pending_ref(state, ref, {:resolve_tool, ref, action})
  end

  def handle_cast({:auto_approve, ref}, state) do
    dispatch_by_pending_ref(state, ref, {:resolve_tool, ref, "go"})
  end

  def handle_cast({:continue_loop, inference_session_id}, state)
      when is_integer(inference_session_id) do
    dispatch_to_inference_session(
      state,
      inference_session_id,
      {:continue_loop, inference_session_id}
    )
  end

  def handle_cast({:stop_loop, inference_session_id}, state)
      when is_integer(inference_session_id) do
    dispatch_to_inference_session(state, inference_session_id, {:stop_loop, inference_session_id})
  end

  def handle_cast({:abort_tool, ref}, state) do
    dispatch_by_executing_ref(state, ref, {:abort_tool, ref})
  end

  def handle_cast(_, state), do: {:noreply, state}

  defp dispatch_to_inference_session(state, inference_session_id, message)
       when is_integer(inference_session_id) do
    SessionScheduler.dispatch(state.scheduler, inference_session_id, message)
    {:noreply, state}
  end

  defp dispatch_by_pending_ref(state, ref, message) when is_binary(ref) do
    case SessionLookup.pending_session_id_for_ref(state.config.id, ref) do
      id when is_integer(id) ->
        dispatch_to_inference_session(state, id, message)

      _ ->
        Logger.warning(event: :pending_ref_not_found, bot_id: state.config.id, ref: ref)
        {:noreply, state}
    end
  end

  defp dispatch_by_pending_ref(state, _ref, _message), do: {:noreply, state}

  defp dispatch_by_executing_ref(state, ref, message) when is_binary(ref) do
    case SessionLookup.executing_session_id_for_ref(state.config.id, ref) do
      id when is_integer(id) ->
        dispatch_to_inference_session(state, id, message)

      _ ->
        Logger.warning(event: :executing_ref_not_found, bot_id: state.config.id, ref: ref)
        {:noreply, state}
    end
  end

  defp dispatch_by_executing_ref(state, _ref, _message), do: {:noreply, state}
end
