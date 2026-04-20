defmodule Froth.Agent.CycleRuntime do
  @moduledoc """
  Supervised process driving one agent cycle.

  Every cycle — bot-owned root or subagent — is a
  `Froth.Agent.CycleRuntime`. Root cycles are started under the owning
  Bot's private cycle supervisor; subagent cycles are started under
  their parent runtime's own child DynamicSupervisor. Runtimes are
  registered in `Froth.Agent.CycleRegistry` keyed by `cycle_id`
  (globally unique), so any caller can address a live cycle via
  `Registry.lookup/2` or the `via/1` helper without going through the
  Bot after startup.

  See `rfc/froth-rfc0021.xml` for the full design.

  ## Responsibilities

  * Own the `Froth.Agent.Worker` for this cycle. Worker is started with
    `tool_executor: self()` so prepare/commit/execute tool calls land
    here, not on the Bot.
  * Hold per-cycle live state: `bot_config` (a snapshot), `chat_id`,
    `reply_to`, `narration`, `last_sent`, `awaiting_user_input?`,
    and `active_tasks`.
  * Drive tool execution, narration edits, and last-sent bookkeeping.
  * On finish, append the per-cycle cost footer and hand back any
    buffered user messages so the Bot can start a follow-up cycle.
  """

  use GenServer, restart: :temporary

  alias Froth.Agent.{Config, Cycle, Surface, ToolUse, Worker}
  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Telegram.{Bot, Bots}
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.{CostFooter, ToolExecution}

  @registry Froth.Agent.CycleRegistry

  @type last_sent :: %{id: integer() | nil, text: binary()}
  @type narration :: %{message_id: integer(), text: binary(), mode: :italic | :markdown}

  @type opts :: [
          cycle_id: String.t(),
          bot_id: String.t() | nil,
          bot_ref: pid() | atom() | {:via, module(), term()} | nil,
          parent_cycle_id: String.t() | nil,
          cycle: Cycle.t() | nil,
          worker_config: Config.t() | nil,
          bot_config: BotConfig.t() | nil,
          bot_pid: pid() | nil,
          chat_id: integer() | nil,
          reply_to: integer() | nil,
          spam: boolean()
        ]

  # --- Public API ---

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    cycle_id = Keyword.fetch!(opts, :cycle_id)
    GenServer.start_link(__MODULE__, opts, name: via(cycle_id))
  end

  @doc """
  The `:via` tuple used to address a cycle runtime by its cycle id.
  Use with `GenServer.call/cast` or as a `name:` option.
  """
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(cycle_id) when is_binary(cycle_id) do
    {:via, Registry, {@registry, cycle_id}}
  end

  @doc "Returns the runtime pid for `cycle_id`, or `nil` if no live cycle has that id."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(cycle_id) when is_binary(cycle_id) do
    case Registry.lookup(@registry, cycle_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Start a bot-owned root cycle runtime under the resolved Bot's private
  cycle supervisor. Returns `{:ok, pid}` on success.
  """
  @spec start_for_bot(String.t() | pid() | atom() | {:via, module(), term()}, opts()) ::
          DynamicSupervisor.on_start_child() | {:error, :bot_not_running}
  def start_for_bot(bot_ref, opts) when is_list(opts) do
    Bot.start_cycle_runtime(bot_ref, opts)
  end

  @doc """
  Forward a pending-ask resolution to the Worker owned by this runtime.
  See `Froth.Agent.Worker.resolve_pending_ask/3`.
  """
  @spec resolve_pending_ask(pid(), String.t(), term()) :: term()
  def resolve_pending_ask(runtime_pid, pending_ask_id, resolution)
      when is_pid(runtime_pid) and is_binary(pending_ask_id) do
    GenServer.call(
      runtime_pid,
      {:resolve_pending_ask, pending_ask_id, resolution},
      :infinity
    )
  end

  @doc """
  Register a background task id (e.g. `"shell:abc"`, `"eval:xyz"`) as
  spawned by this cycle. Idempotent. Silently no-ops if no live runtime
  is registered for `cycle_id`.
  """
  @spec register_task(String.t(), String.t()) :: :ok
  def register_task(cycle_id, task_id)
      when is_binary(cycle_id) and is_binary(task_id) do
    case whereis(cycle_id) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:register_task, task_id})
      nil -> :ok
    end
  end

  @doc """
  Return the sorted list of background task ids currently tracked by
  the runtime for `cycle_id`. Returns `[]` when `cycle_id` is nil or
  no runtime is live for that id.
  """
  @spec active_task_ids(String.t() | nil) :: [String.t()]
  def active_task_ids(cycle_id) when is_binary(cycle_id) do
    case whereis(cycle_id) do
      pid when is_pid(pid) -> GenServer.call(pid, :active_task_ids)
      nil -> []
    end
  end

  def active_task_ids(nil), do: []

  @doc """
  Fan out a TDLib `updateMessageSendSucceeded` to every live cycle
  runtime so each can swap old temp ids for final ids on its
  `narration` and `last_sent` fields. Called from the Bot's PubSub
  handler.
  """
  @spec sync_sent_message_id(integer(), integer()) :: :ok
  def sync_sent_message_id(old_id, new_id)
      when is_integer(old_id) and is_integer(new_id) do
    # Broadcast the id swap to every live cycle runtime. A cycle's
    # `swap_id` is a no-op if neither its `:last_sent` nor its
    # `:narration` references `old_id`, so fan-out is cheap and
    # correct even across cycles that don't own this temp id.
    for pid <- Registry.select(@registry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      GenServer.cast(pid, {:sync_sent_message_id, old_id, new_id})
    end

    :ok
  end

  @doc """
  Clear the `awaiting_user_input?` flag — called by the Bot when a
  pending ask is resolved.
  """
  @spec clear_awaiting_user_input(String.t()) :: :ok
  def clear_awaiting_user_input(cycle_id) when is_binary(cycle_id) do
    case whereis(cycle_id) do
      pid when is_pid(pid) -> GenServer.cast(pid, :clear_awaiting_user_input)
      nil -> :ok
    end
  end

  @doc """
  Record a message sent outside the tool-execution path (e.g. the
  Bot's fallback when an agent produces a bare text response instead
  of calling `send_message`). Updates `last_sent` and clears narration.
  """
  @spec track_sent_message(String.t(), map(), String.t()) :: :ok
  def track_sent_message(cycle_id, sent, text)
      when is_binary(cycle_id) and is_map(sent) and is_binary(text) do
    case whereis(cycle_id) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:track_sent_message, sent, text})
      nil -> :ok
    end
  end

  @doc """
  Spawn a subagent cycle as a child of `parent_pid`'s cycle. The new
  runtime is started under the parent runtime's own unnamed
  `DynamicSupervisor`, so parent termination cascades to children via
  BEAM supervision.

  `opts` must include `:cycle_id`, `:cycle`, and `:worker_config` (the
  child's own `%Froth.Agent.Config{}` — `tool_executor` is overridden
  to the child runtime's pid in its `init/1`). Identity and surface
  default to the parent's when not explicitly provided: `:bot_id`,
  `:bot_config`, `:bot_pid`, `:chat_id`, `:reply_to`.
  """
  @spec spawn_subagent(pid(), opts()) :: DynamicSupervisor.on_start_child()
  def spawn_subagent(parent_pid, opts) when is_pid(parent_pid) and is_list(opts) do
    GenServer.call(parent_pid, {:spawn_subagent, opts})
  end

  @doc """
  Convenience wrapper that looks up the parent runtime by its
  `cycle_id` in the registry before calling `spawn_subagent/2`.
  """
  @spec spawn_subagent_by_cycle_id(String.t(), opts()) ::
          DynamicSupervisor.on_start_child() | {:error, :parent_not_found}
  def spawn_subagent_by_cycle_id(parent_cycle_id, opts)
      when is_binary(parent_cycle_id) and is_list(opts) do
    case whereis(parent_cycle_id) do
      pid when is_pid(pid) -> spawn_subagent(pid, opts)
      nil -> {:error, :parent_not_found}
    end
  end

  @doc """
  Lazily start a bot-owned runtime and return an `Enumerable` of events
  it publishes on `"cycle:<cycle_id>"`. The runtime is *not* started
  until the stream is consumed — matching the old `Agent.cycle_stream/2`
  semantics — so PubSub subscription and runtime start are guaranteed
  to happen in that order, with no events lost.

  The stream halts when the runtime exits `:normal`; an abnormal exit
  raises through `exit/1`.

  `opts` are passed through to `start_for_bot/2` and must include at
  least `:cycle_id`, `:cycle`, and `:worker_config`, plus bot ownership
  via `:bot_id` or explicit `:bot_ref`.
  """
  @spec event_stream_for(opts()) :: Enumerable.t()
  def event_stream_for(opts) when is_list(opts) do
    cycle_id = Keyword.fetch!(opts, :cycle_id)
    bot_ref = bot_ref_from_opts!(opts)

    Stream.resource(
      fn ->
        :ok = Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle_id}")
        {:ok, runtime_pid} = start_for_bot(bot_ref, opts)
        ref = Process.monitor(runtime_pid)
        {runtime_pid, ref, cycle_id}
      end,
      fn {pid, ref, _cid} = acc ->
        receive do
          {:stream, event} ->
            {[{:stream, event}], acc}

          {:event, event, msg} ->
            {[{:event, event, msg}], acc}

          {:DOWN, ^ref, :process, ^pid, :normal} ->
            {:halt, acc}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            exit(reason)
        end
      end,
      fn {_pid, _ref, cid} ->
        Phoenix.PubSub.unsubscribe(Froth.PubSub, "cycle:#{cid}")
      end
    )
  end

  @doc """
  Run a top-level cycle to completion and return the final agent
  message text. Convenience wrapper around `event_stream_for/1` +
  reducing over the stream for the last agent message.
  """
  @spec run_to_completion(opts()) :: {Cycle.t(), String.t() | nil}
  def run_to_completion(opts) when is_list(opts) do
    cycle_id = Keyword.fetch!(opts, :cycle_id)

    last_message =
      opts
      |> event_stream_for()
      |> Enum.reduce(nil, fn
        {:event, _event, %Froth.Agent.Message{role: :agent} = message}, _acc -> message
        _other, acc -> acc
      end)

    refreshed = Froth.Repo.get!(Cycle, cycle_id)
    output = last_message && Froth.Agent.Message.extract_text(last_message)
    {refreshed, output}
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) when is_list(opts) do
    # Trap exits so that (a) terminate/2 runs on supervised shutdown
    # (for cycle-footer cleanup) and (b) Worker exits arrive as EXIT
    # messages instead of crashing us linked.
    Process.flag(:trap_exit, true)

    Froth.Repo.allow(Keyword.get(opts, :bot_pid), "cycle_runtime")

    cycle = Keyword.get(opts, :cycle)
    worker_config = Keyword.get(opts, :worker_config)
    bc = Keyword.get(opts, :bot_config)
    chat_id = Keyword.get(opts, :chat_id)

    {:ok, children_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    context = %Context{
      cycle_id: Keyword.fetch!(opts, :cycle_id),
      cycle: cycle,
      bot_config: bc,
      surface: %Surface{
        session_id: bc && bc.session_id,
        chat_id: chat_id,
        reply_to: Keyword.get(opts, :reply_to)
      },
      view: %View{},
      spam: Keyword.get(opts, :spam, true),
      system_prompt: bc && BotConfig.resolve_system_prompt(chat_id || 0, nil, bc),
      tool_specs: BotConfig.resolve_tool_specs(bc)
    }

    state = %{
      context: context,
      parent_cycle_id: Keyword.get(opts, :parent_cycle_id),
      worker_pid: nil,
      bot_pid: Keyword.get(opts, :bot_pid),
      children_sup: children_sup
    }

    case maybe_start_worker(cycle, worker_config) do
      {:ok, worker_pid} ->
        {:ok, %{state | worker_pid: worker_pid}}

      :skip ->
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call(:active_task_ids, _from, state) do
    {:reply, state.context.view.active_task_ids, state}
  end

  def handle_call({:resolve_pending_ask, pending_ask_id, resolution}, _from, state) do
    case state.worker_pid do
      pid when is_pid(pid) ->
        reply = Worker.resolve_pending_ask(pid, pending_ask_id, resolution)
        {:reply, reply, state}

      nil ->
        {:reply, {:error, :no_worker}, state}
    end
  end

  def handle_call({:prepare_tool, %ToolUse{} = tool_use, invocation}, _from, state) do
    {reply, state} = prepare_tool_call(state, tool_use, invocation)
    {:reply, reply, state}
  end

  def handle_call(
        {:commit_tool, %ToolUse{} = tool_use, invocation, prepared, outcome},
        _from,
        state
      ) do
    {reply, state} = commit_tool_call(state, tool_use, invocation, prepared, outcome)
    {:reply, reply, state}
  end

  def handle_call({:spawn_subagent, opts}, _from, state) when is_list(opts) do
    %Context{
      cycle_id: cycle_id,
      bot_config: bc,
      surface: %Surface{chat_id: chat_id, reply_to: reply_to},
      spam: spam
    } = state.context

    child_opts =
      opts
      |> Keyword.put_new(:parent_cycle_id, cycle_id)
      |> Keyword.put_new(:bot_id, bc && bc.id)
      |> Keyword.put_new(:bot_config, bc)
      |> Keyword.put_new(:bot_pid, state.bot_pid)
      |> Keyword.put_new(:chat_id, chat_id)
      |> Keyword.put_new(:reply_to, reply_to)
      |> Keyword.put_new(:spam, spam)

    reply = DynamicSupervisor.start_child(state.children_sup, {__MODULE__, child_opts})
    {:reply, reply, state}
  end

  def handle_call({:execute, %ToolUse{} = tool_use, invocation}, _from, state) do
    {reply, state} = prepare_tool_call(state, tool_use, invocation)

    {result, state} =
      case reply do
        {:ok, prepared} ->
          outcome = ToolExecution.execute(prepared.context, prepared.tool_call)
          commit_tool_call(state, tool_use, invocation, prepared, outcome)

        {:error, reason} ->
          {{:error, reason}, state}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:register_task, task_id}, state) when is_binary(task_id) do
    {:noreply, update_view(state, &add_task_id(&1, task_id))}
  end

  def handle_cast({:sync_sent_message_id, old_id, new_id}, state)
      when is_integer(old_id) and is_integer(new_id) do
    {:noreply,
     update_view(state, fn %View{} = view ->
       %View{
         view
         | last_sent: swap_id(view.last_sent, :id, old_id, new_id),
           narration: swap_id(view.narration, :message_id, old_id, new_id)
       }
     end)}
  end

  def handle_cast(:clear_awaiting_user_input, state) do
    {:noreply, update_view(state, fn %View{} = v -> %View{v | awaiting_user_input?: false} end)}
  end

  def handle_cast({:track_sent_message, sent, text}, state) when is_binary(text) do
    {:noreply, update_view(state, &apply_sent_message(&1, sent, text))}
  end

  @impl true
  def handle_info({:EXIT, worker_pid, reason}, %{worker_pid: worker_pid} = state) do
    # Worker terminated. Mirror its reason — a normal Worker finish
    # ends the cycle runtime normally; a crash propagates the reason
    # up so the Bot's monitor sees it unchanged.
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = maybe_append_cycle_footer(state.context)
    :ok
  end

  # Nested-update helper: apply a View -> View function to
  # `state.context.view`, returning the new state.
  defp update_view(state, fun) when is_function(fun, 1) do
    %Context{} = ctx = state.context
    %{state | context: %Context{ctx | view: fun.(ctx.view)}}
  end

  # --- Worker lifecycle ---

  defp maybe_start_worker(%Cycle{} = cycle, %Config{} = config) do
    # Point the Worker's tool_executor at this runtime so prepare /
    # commit / execute tool calls land here instead of the Bot.
    config = %{config | tool_executor: self()}

    case Worker.start_link({cycle, config}) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  # Any combination without a Worker config is "scaffolding mode" — no
  # Worker, just the state shell. Production paths always pass both.
  defp maybe_start_worker(_cycle, nil), do: :skip

  # --- Tool execution ---

  # Produce a per-call `%Context{}` from `state.context` (with surface
  # overrides from the Worker's `invocation` kwlist applied) and the
  # per-call `%ToolUse{}` with its input shape-tweaked. `ToolExecution`
  # takes them as two arguments — cycle-level context + per-call tool
  # call — so the nullable-tool_call kludge goes away.
  defp prepare_tool_call(state, %ToolUse{name: name, input: input} = tool_use, invocation)
       when is_map(input) do
    %Context{} = base = state.context
    surface = overlay_surface(base.surface, invocation)
    shaped_input = shape_tool_input(name, input, base.cycle_id, surface.reply_to)
    tool_call = %ToolUse{tool_use | input: shaped_input}

    ctx = %Context{base | surface: surface}

    prepared = %{
      context: ctx,
      tool_call: tool_call,
      execute: {ToolExecution, :execute, [ctx, tool_call]}
    }

    {{:ok, prepared}, state}
  end

  defp prepare_tool_call(state, _tool_use, _invocation),
    do: {{:error, "invalid tool input"}, state}

  defp overlay_surface(%Surface{} = base, invocation) do
    %Surface{
      session_id: base.session_id,
      chat_id: invocation[:chat_id] || base.chat_id,
      reply_to: invocation[:reply_to] || base.reply_to
    }
  end

  defp shape_tool_input("elixir_eval", input, cycle_id, reply_to) do
    input
    |> Map.put("reply_to", reply_to)
    |> Map.put("topic", "cycle:#{cycle_id}")
  end

  defp shape_tool_input(name, input, _cycle_id, reply_to)
       when name in ["run_shell", "spawn_agent"] do
    Map.put(input, "reply_to", reply_to)
  end

  defp shape_tool_input(_name, input, _cycle_id, _reply_to), do: input

  defp commit_tool_call(state, _tool_use, _invocation, _prepared, outcome) do
    {result, sent_message, narration_message, awaiting_user_input?} =
      case outcome do
        %{result: result} = o ->
          {result, o[:sent_message], o[:narration_message], o[:awaiting_user_input] == true}

        result ->
          {result, nil, nil, false}
      end

    state =
      update_view(state, fn view ->
        view
        |> apply_narration_message(narration_message)
        |> apply_sent_or_awaiting(sent_message, awaiting_user_input?)
        |> apply_task_from_result(result)
      end)

    {result, state}
  end

  defp apply_narration_message(%View{} = view, %{message_id: mid, text: text, mode: mode})
       when is_integer(mid) and is_binary(text) and mode in [:italic, :markdown] do
    %View{view | narration: %{message_id: mid, text: text, mode: mode}}
  end

  defp apply_narration_message(%View{} = view, _), do: view

  defp apply_sent_or_awaiting(%View{} = view, %{sent: sent, text: text}, true)
       when is_binary(text) do
    apply_awaiting_user_input(view, sent, text)
  end

  defp apply_sent_or_awaiting(%View{} = view, %{sent: sent, text: text}, false)
       when is_binary(text) do
    apply_sent_message(view, sent, text)
  end

  defp apply_sent_or_awaiting(%View{} = view, _sent_message, _awaiting?), do: view

  defp apply_task_from_result(%View{} = view, {:ok, result}) do
    case extract_task_id(result) do
      task_id when is_binary(task_id) -> add_task_id(view, task_id)
      _ -> view
    end
  end

  defp apply_task_from_result(%View{} = view, _result), do: view

  defp add_task_id(%View{active_task_ids: ids} = view, task_id) when is_binary(task_id) do
    %View{view | active_task_ids: Enum.sort(Enum.uniq([task_id | ids]))}
  end

  defp extract_task_id(text) when is_binary(text) do
    case Regex.run(~r/\btask_id=([a-z]+:[a-zA-Z0-9:_-]+)/, text, capture: :all_but_first) do
      [task_id] -> task_id
      _ -> extract_shell_task_id(text)
    end
  end

  defp extract_task_id(_), do: nil

  defp extract_shell_task_id(text) when is_binary(text) do
    case Regex.run(~r/\bshell task ([a-z]+:[a-zA-Z0-9:_-]+)/, text, capture: :all_but_first) do
      [task_id] -> task_id
      _ -> nil
    end
  end

  # --- Narration / last-sent helpers (View -> View) ---

  defp apply_sent_message(%View{} = view, sent, text) when is_binary(text) do
    %View{
      view
      | narration: nil,
        awaiting_user_input?: false,
        last_sent: build_last_sent(sent, text)
    }
  end

  defp apply_sent_message(view, _sent, _text), do: view

  defp apply_awaiting_user_input(%View{} = view, sent, text) when is_binary(text) do
    %View{
      view
      | narration: nil,
        awaiting_user_input?: true,
        last_sent: build_last_sent(sent, text)
    }
  end

  defp apply_awaiting_user_input(view, _sent, _text), do: view

  defp build_last_sent(sent, text) do
    case sent_message_id(sent) do
      id when is_integer(id) -> %{id: id, text: text}
      _ -> %{id: nil, text: text}
    end
  end

  defp sent_message_id(%{"id" => id}) when is_integer(id), do: id

  defp sent_message_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp sent_message_id(_), do: nil

  # --- Cycle footer on finish ---

  defp maybe_append_cycle_footer(%Context{
         cycle_id: cycle_id,
         cycle: %Cycle{id: cycle_id},
         bot_config: %BotConfig{} = bc,
         surface: %Surface{chat_id: chat_id, reply_to: reply_to},
         view: %View{
           last_sent: %{id: msg_id, text: text},
           awaiting_user_input?: false
         }
       })
       when is_binary(cycle_id) and is_integer(msg_id) and is_binary(text) and is_integer(chat_id) do
    # Tolerate a bad `cycle_id` (e.g. a non-ULID test fixture) so
    # terminate/2 doesn't log a confusing Ecto cast error.
    footer =
      try do
        CostFooter.render_for_cycle_id(cycle_id)
      rescue
        _ -> nil
      end

    case footer do
      nil ->
        :ok

      footer ->
        CostFooter.apply(
          session_id: bc.session_id,
          chat_id: chat_id,
          last_sent_message_id: msg_id,
          last_sent_message_text: text,
          footer: footer,
          reply_to: reply_to
        )
    end
  end

  defp maybe_append_cycle_footer(_ctx), do: :ok

  # --- Misc helpers ---

  defp bot_ref_from_opts!(opts) when is_list(opts) do
    cond do
      ref = Keyword.get(opts, :bot_ref) ->
        ref

      is_binary(Keyword.get(opts, :bot_id)) ->
        Bots.via(Keyword.fetch!(opts, :bot_id))

      true ->
        raise ArgumentError,
              "bot-owned cycle runtime requires :bot_id or :bot_ref in runtime opts"
    end
  end

  defp swap_id(%{} = map, key, old_id, new_id) do
    case Map.get(map, key) do
      ^old_id -> Map.put(map, key, new_id)
      _ -> map
    end
  end

  defp swap_id(other, _key, _old_id, _new_id), do: other
end
