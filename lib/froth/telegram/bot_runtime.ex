defmodule Froth.Telegram.BotRuntime do
  @moduledoc """
  Telegram transport/runtime process for a single bot instance.

  This process subscribes to Telegram updates, maps them into runtime actions,
  and forwards those actions to an `Froth.Inference.Orchestrator`.
  """

  use GenServer
  require Logger

  alias Froth.Inference.Orchestrator
  alias Froth.Inference.RuntimeConfig
  alias Froth.Telegram.BotAdapter
  alias Froth.Telegram.ToolLoopPrompts
  alias Froth.Telegram.UpdateRouter

  def start_link(opts \\ [])

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    config = RuntimeConfig.build(opts)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @impl true
  def init(config) when is_map(config) do
    {:ok, orchestrator} = Orchestrator.start_link(Map.put(config, :name, nil))
    :ok = BotAdapter.subscribe(config.session_id)
    Logger.info(event: :listening, bot_id: config.id, session_id: config.session_id)
    {:ok, %{config: config, orchestrator: orchestrator}}
  end

  @impl true
  def handle_info({:telegram_update, update}, state) do
    case UpdateRouter.route_update(update,
           bot_username: state.config.bot_username,
           bot_user_id: state.config.bot_user_id,
           owner_user_id: state.config.owner_user_id,
           name_triggers: state.config.name_triggers,
           session_id: state.config.session_id
         ) do
      {:start_inference_session, msg} ->
        Orchestrator.start_inference_session(state.orchestrator, msg)
        {:noreply, state}

      {:callback, query_id, {:stop_loop, inference_session_id}} ->
        BotAdapter.answer_callback(state.config.session_id, query_id)
        Orchestrator.stop_loop(state.orchestrator, inference_session_id)
        {:noreply, state}

      {:callback, query_id, {:resolve_tool, ref, action}} ->
        BotAdapter.answer_callback(state.config.session_id, query_id)
        Orchestrator.resolve_tool(state.orchestrator, ref, action)
        {:noreply, state}

      {:callback, query_id, :ignore} ->
        BotAdapter.answer_callback(state.config.session_id, query_id)
        {:noreply, state}

      {:sync_prompt_message_id, old_id, new_id, chat_id} ->
        :ok =
          ToolLoopPrompts.sync_pending_prompt_message_id(state.config.id, old_id, new_id, chat_id)

        {:noreply, state}

      {:message_send_failed, failed_update} ->
        Logger.error(event: :message_send_failed, update: inspect(failed_update, limit: 500))
        {:noreply, state}

      :ignore ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:start_inference_session, msg}, state) when is_map(msg) do
    Orchestrator.start_inference_session(state.orchestrator, msg)
    {:noreply, state}
  end

  def handle_cast({:auto_approve, ref}, state) when is_binary(ref) do
    Orchestrator.auto_approve(state.orchestrator, ref)
    {:noreply, state}
  end

  def handle_cast({:continue_loop, inference_session_id}, state)
      when is_integer(inference_session_id) do
    Orchestrator.continue_loop(state.orchestrator, inference_session_id)
    {:noreply, state}
  end

  def handle_cast({:stop_loop, inference_session_id}, state)
      when is_integer(inference_session_id) do
    Orchestrator.stop_loop(state.orchestrator, inference_session_id)
    {:noreply, state}
  end

  def handle_cast({:abort_tool, ref}, state) when is_binary(ref) do
    Orchestrator.abort_tool(state.orchestrator, ref)
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}
end
