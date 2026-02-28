defmodule Froth.Codex.Session do
  @moduledoc """
  Shared Codex app-server runtime session.

  A session is keyed by `session_id` and can be viewed/controlled by many
  LiveView clients concurrently. The runtime persists while the process is
  alive, so browser reloads do not restart Codex work.
  """

  use GenServer

  alias Froth.Codex.Events, as: CodexEvents
  alias Froth.Telemetry.Span

  @registry Froth.Codex.SessionRegistry
  @supervisor Froth.Codex.SessionSupervisor
  @pubsub Froth.PubSub
  @request_timeout_ms 120_000
  @max_entries 800

  @type session_id :: String.t()
  @type snapshot :: %{
          session_id: session_id(),
          status: atom(),
          thread_id: String.t() | nil,
          active_turn_id: String.t() | nil,
          entries: [map()],
          token_usage: map() | nil,
          rate_limits: map() | nil,
          auth: map() | nil,
          runtime: map() | nil
        }

  # --- Public API ---

  @spec ensure_started(session_id(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    session_id = String.trim(session_id)
    requested_thread_id = thread_id_from_opts(opts)

    case whereis(session_id) do
      nil ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, [session_id: session_id, thread_id: requested_thread_id]}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      pid ->
        if is_binary(requested_thread_id) do
          GenServer.cast(pid, {:resume_thread_if_missing, requested_thread_id})
        end

        {:ok, pid}
    end
  end

  @spec whereis(session_id()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec topic(session_id()) :: String.t()
  def topic(session_id) when is_binary(session_id), do: "codex:session:#{session_id}"

  @spec subscribe(session_id()) :: :ok | {:error, term()}
  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  @spec snapshot(session_id()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(session_id) when is_binary(session_id) do
    with {:ok, pid} <- ensure_started(session_id),
         result when is_map(result) <-
           GenServer.call(pid, :snapshot, @request_timeout_ms + 1_000) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :snapshot_failed}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :session_not_running}
    :exit, reason -> {:error, reason}
  end

  @spec send_prompt(session_id(), String.t()) :: :ok | {:error, term()}
  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    call_session(session_id, {:send_prompt, prompt})
  end

  @spec new_thread(session_id()) :: :ok | {:error, term()}
  def new_thread(session_id) when is_binary(session_id), do: call_session(session_id, :new_thread)

  @spec interrupt_turn(session_id()) :: :ok | {:error, term()}
  def interrupt_turn(session_id) when is_binary(session_id) do
    call_session(session_id, :interrupt_turn)
  end

  @spec current_thread_id(session_id()) :: {:ok, String.t() | nil} | {:error, term()}
  def current_thread_id(session_id) when is_binary(session_id) do
    with {:ok, snap} <- snapshot(session_id), do: {:ok, snap.thread_id}
  end

  # --- GenServer setup ---

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    thread_id = Keyword.get(opts, :thread_id)

    GenServer.start_link(__MODULE__, %{session_id: session_id, thread_id: thread_id},
      name: {:via, Registry, {@registry, session_id}}
    )
  end

  @impl true
  def init(%{session_id: session_id, thread_id: requested_thread_id}) do
    Process.flag(:trap_exit, true)
    {restored_entries, restored_seq} = CodexEvents.load_recent_entries(session_id, @max_entries)

    state = %{
      session_id: session_id,
      codex_pid: nil,
      codex_topic: "codex:wire:#{session_id}",
      status: :booting,
      thread_id: nil,
      active_turn_id: nil,
      active_assistant_entry_id: nil,
      active_assistant_text: "",
      active_reasoning_entry_id: nil,
      active_reasoning_text: "",
      tool_entry_ids_by_call: %{},
      token_usage: nil,
      rate_limits: nil,
      auth: nil,
      runtime: nil,
      seen_misc_methods: MapSet.new(),
      entry_seq: restored_seq,
      entries: restored_entries
    }

    state =
      if restored_entries == [] do
        state
        |> push_entry(:system, "starting codex...")
        |> push_entry(:status, "session #{session_id}")
      else
        state
      end

    send(self(), {:boot, requested_thread_id})
    {:ok, state}
  end

  # --- handle_call ---

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:send_prompt, prompt}, _from, state) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:reply, {:error, :empty_prompt}, state}
    else
      case do_send_prompt(state, prompt) do
        {:ok, state} -> {:reply, :ok, broadcast_update(state)}
        {:error, reason, state} -> {:reply, {:error, reason}, broadcast_update(state)}
      end
    end
  end

  def handle_call(:new_thread, _from, state) do
    case do_start_new_thread(state, true) do
      {:ok, state} -> {:reply, :ok, broadcast_update(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, broadcast_update(state)}
    end
  end

  def handle_call(:interrupt_turn, _from, state) do
    case do_interrupt_turn(state) do
      {:ok, state} -> {:reply, :ok, broadcast_update(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, broadcast_update(state)}
    end
  end

  @impl true
  def handle_cast({:resume_thread_if_missing, requested_thread_id}, state) do
    state =
      if is_nil(state.thread_id) and is_binary(requested_thread_id) do
        case resume_thread(state, requested_thread_id) do
          {:ok, s} -> s
          {:error, _, s} -> s
        end
      else
        state
      end

    {:noreply, broadcast_update(state)}
  end

  # --- handle_info ---

  @impl true
  def handle_info({:boot, requested_thread_id}, state) do
    state = boot_codex(state)

    state =
      cond do
        state.status != :ready ->
          state

        is_binary(requested_thread_id) ->
          case resume_thread(state, requested_thread_id) do
            {:ok, s} -> s
            {:error, _, s} -> s
          end

        true ->
          case do_start_new_thread(state, false) do
            {:ok, s} -> s
            {:error, _, s} -> s
          end
      end

    {:noreply, broadcast_update(state)}
  end

  def handle_info({:codex, :notification, method, params, _raw, _raw_line}, state)
      when is_binary(method) and is_map(params) do
    state = safely_apply_notification(state, method, params)
    {:noreply, broadcast_update(state)}
  end

  def handle_info({:codex, :notification, method, params, raw}, state)
      when is_binary(method) and is_map(params) do
    handle_info({:codex, :notification, method, params, raw, nil}, state)
  end

  def handle_info({:codex, :protocol_error, reason}, state) do
    state = push_entry(state, :error, "protocol error: #{inspect(reason)}")
    {:noreply, broadcast_update(state)}
  end

  def handle_info({:EXIT, pid, reason}, %{codex_pid: pid} = state) when is_pid(pid) do
    Span.execute([:froth, :codex, :session_codex_exit], nil, %{
      session_id: state.session_id,
      reason: inspect(reason)
    })

    state =
      state
      |> Map.put(:codex_pid, nil)
      |> Map.put(:status, :error)
      |> Map.put(:active_turn_id, nil)
      |> Map.put(:auth, nil)
      |> reset_turn_state()
      |> push_entry(:error, "codex exited: #{inspect(reason)}")

    {:noreply, broadcast_update(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.codex_pid) and Process.alive?(state.codex_pid) do
      _ = Froth.Codex.stop(state.codex_pid)
    end

    :ok
  end

  # --- Core operations ---

  defp call_session(session_id, message) do
    with {:ok, pid} <- ensure_started(session_id) do
      GenServer.call(pid, message, @request_timeout_ms + 1_000)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :session_not_running}
    :exit, reason -> {:error, reason}
  end

  defp boot_codex(state) do
    case Froth.Codex.start_link(
           name: nil,
           topic: state.codex_topic,
           cwd: File.cwd!(),
           request_timeout: @request_timeout_ms
         ) do
      {:ok, pid} ->
        with :ok <- Froth.Codex.subscribe(pid),
             {:ok, _} <- Froth.Codex.handshake(pid, client_info(state.session_id)) do
          state
          |> Map.put(:codex_pid, pid)
          |> Map.put(:status, :ready)
          |> push_entry(:system, "connected")
          |> refresh_auth_status()
          |> refresh_runtime_config()
        else
          {:error, reason} ->
            if Process.alive?(pid), do: Froth.Codex.stop(pid)

            state
            |> Map.put(:status, :error)
            |> push_entry(:error, "initialize failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        state
        |> Map.put(:status, :error)
        |> push_entry(:error, "failed to start codex: #{inspect(reason)}")
    end
  end

  defp do_send_prompt(state, prompt) do
    with {:ok, state} <- ensure_ready(state),
         {:ok, state} <- ensure_thread(state) do
      state = push_entry(state, :user, prompt)

      params = %{
        "threadId" => state.thread_id,
        "input" => [%{"type" => "text", "text" => prompt}]
      }

      case codex_call(state, :turn_start, params) do
        {:ok, result} ->
          {:ok, state |> Map.put(:active_turn_id, get_turn_id(result)) |> reset_turn_state()}

        {:error, reason} ->
          {:error, reason, push_entry(state, :error, "turn/start failed: #{inspect(reason)}")}
      end
    end
  end

  defp do_start_new_thread(state, reset_feed?) do
    state =
      if reset_feed? do
        state
        |> Map.merge(%{entries: [], entry_seq: 0, active_turn_id: nil})
        |> reset_turn_state()
        |> push_entry(:status, "starting new thread")
      else
        state
      end

    with {:ok, state} <- ensure_ready(state) do
      params = %{
        "cwd" => File.cwd!(),
        "approvalPolicy" => "never",
        "sandbox" => "workspace-write",
        "personality" => "friendly"
      }

      case codex_call(state, :thread_start, params) do
        {:ok, result} ->
          case get_thread_id(result) do
            thread_id when is_binary(thread_id) ->
              state =
                state
                |> apply_runtime_patch(result, params)
                |> Map.put(:thread_id, thread_id)
                |> Map.put(:active_turn_id, nil)
                |> reset_turn_state()
                |> push_entry(:system, "thread started #{short_id(thread_id)}")

              {:ok, state}

            _ ->
              {:error, :missing_thread_id,
               push_entry(state, :error, "thread/start returned no thread id")}
          end

        {:error, reason} ->
          {:error, reason, push_entry(state, :error, "thread/start failed: #{inspect(reason)}")}
      end
    end
  end

  defp do_interrupt_turn(%{active_turn_id: nil} = state) do
    {:error, :no_active_turn, push_entry(state, :status, "no active turn")}
  end

  defp do_interrupt_turn(state) do
    with {:ok, state} <- ensure_ready(state),
         thread_id when is_binary(thread_id) <- state.thread_id do
      params = %{"threadId" => thread_id, "turnId" => state.active_turn_id}

      case codex_call(state, :turn_interrupt, params) do
        {:ok, _} ->
          {:ok, push_entry(state, :status, "interrupt requested")}

        {:error, reason} ->
          {:error, reason, push_entry(state, :error, "interrupt failed: #{inspect(reason)}")}
      end
    else
      {:error, reason, state} -> {:error, reason, state}
      _ -> {:error, :missing_thread, push_entry(state, :error, "cannot interrupt without thread")}
    end
  end

  defp ensure_ready(%{status: :ready} = state), do: {:ok, state}

  defp ensure_ready(state),
    do: {:error, :codex_not_ready, push_entry(state, :error, "codex not ready")}

  defp ensure_thread(%{thread_id: id} = state) when is_binary(id), do: {:ok, state}
  defp ensure_thread(state), do: do_start_new_thread(state, false)

  defp resume_thread(state, thread_id) when is_binary(thread_id) do
    with {:ok, state} <- ensure_ready(state) do
      case codex_call(state, :thread_resume, %{"threadId" => thread_id}) do
        {:ok, result} ->
          resolved = get_thread_id(result) || thread_id

          state =
            state
            |> apply_runtime_patch(result)
            |> Map.put(:thread_id, resolved)
            |> Map.put(:active_turn_id, nil)
            |> reset_turn_state()
            |> push_entry(:system, "resumed thread #{short_id(resolved)}")

          {:ok, state}

        {:error, reason} ->
          {:error, reason, push_entry(state, :error, "resume failed: #{inspect(reason)}")}
      end
    end
  end

  defp codex_call(state, method, params) when is_map(params) do
    if is_pid(state.codex_pid) and Process.alive?(state.codex_pid) do
      apply(Froth.Codex, method, [state.codex_pid, params, [timeout: @request_timeout_ms]])
    else
      {:error, :codex_not_running}
    end
  end

  # --- Notification dispatch ---

  defp apply_notification(state, "thread/started", params) do
    thread_id = get_thread_id(params)
    state = apply_runtime_patch(state, params)
    state = if is_binary(thread_id), do: Map.put(state, :thread_id, thread_id), else: state

    if is_binary(thread_id),
      do: push_entry(state, :system, "thread ready #{short_id(thread_id)}"),
      else: push_entry(state, :status, "thread started")
  end

  defp apply_notification(state, "thread/configurationUpdated", params) do
    apply_runtime_patch(state, params)
  end

  defp apply_notification(state, "turn/modelConfigurationChanged", params) do
    config = Map.get(params, "configuration") || params

    merge_runtime(state, %{
      model: Map.get(config, "model"),
      model_provider: Map.get(config, "modelProvider"),
      reasoning_effort: Map.get(config, "reasoningEffort")
    })
  end

  defp apply_notification(state, "account/modelPreferencesChanged", params) do
    prefs = Map.get(params, "modelPreferences") || params

    merge_runtime(state, %{
      model: Map.get(prefs, "model"),
      reasoning_effort: Map.get(prefs, "reasoningEffort")
    })
  end

  defp apply_notification(state, "turn/started", params) do
    turn_id = get_turn_id(params)

    state
    |> Map.put(:active_turn_id, turn_id)
    |> reset_turn_state()
    |> push_entry(:status, "working#{if(turn_id, do: " (#{short_id(turn_id)})", else: "")}")
  end

  defp apply_notification(state, "turn/completed", params) do
    turn_status = get_in(params, ["turn", "status"]) || "completed"

    state
    |> Map.put(:active_turn_id, nil)
    |> reset_turn_state()
    |> push_entry(:status, "turn #{turn_status}")
  end

  defp apply_notification(state, "item/agentMessage/delta", %{"delta" => delta} = params)
       when is_binary(delta) do
    assistant_id = state.active_assistant_entry_id || make_assistant_id(params)
    full = state.active_assistant_text <> delta

    state
    |> Map.put(:active_assistant_entry_id, assistant_id)
    |> Map.put(:active_assistant_text, full)
    |> upsert_entry(assistant_id, :assistant, full)
  end

  defp apply_notification(state, "item/completed", %{"item" => %{"type" => type} = item} = params)
       when type in ["agentMessage", "AgentMessage"] do
    text = Map.get(item, "text") || extract_text_from_content(Map.get(item, "content"))
    upsert_assistant_message(state, Map.get(params, "turnId"), Map.get(item, "id"), text)
  end

  defp apply_notification(state, "item/reasoning/summaryPartAdded", params) do
    reasoning_id = make_reasoning_id(params)

    state
    |> Map.put(:active_reasoning_entry_id, reasoning_id)
    |> Map.put(:active_reasoning_text, "")
    |> upsert_entry(reasoning_id, :reasoning, "thinking...")
  end

  defp apply_notification(state, "item/reasoning/summaryTextDelta", %{"delta" => delta} = params)
       when is_binary(delta) do
    reasoning_id = state.active_reasoning_entry_id || make_reasoning_id(params)
    full = state.active_reasoning_text <> delta

    state
    |> Map.put(:active_reasoning_entry_id, reasoning_id)
    |> Map.put(:active_reasoning_text, full)
    |> upsert_entry(reasoning_id, :reasoning, full)
  end

  defp apply_notification(state, "codex/event/exec_command_begin", %{"msg" => msg})
       when is_map(msg) do
    call_id = Map.get(msg, "call_id") || Map.get(msg, "callId")
    command = summarize_command(msg)
    entry_id = "tool-#{call_id || state.entry_seq + 1}"

    state
    |> maybe_track_tool_call(call_id, entry_id)
    |> upsert_entry_map(entry_id, %{
      id: entry_id,
      kind: :tool,
      body: command || "running command",
      status: "running",
      output: nil
    })
  end

  defp apply_notification(state, "codex/event/exec_command_end", %{"msg" => msg})
       when is_map(msg) do
    call_id = Map.get(msg, "call_id") || Map.get(msg, "callId")
    exit_code = Map.get(msg, "exit_code") || Map.get(msg, "exitCode")

    status =
      cond do
        exit_code == 0 -> "ok"
        is_integer(exit_code) -> "error"
        true -> "done"
      end

    entry_id = Map.get(state.tool_entry_ids_by_call, call_id) || "tool-#{state.entry_seq + 1}"

    state
    |> Map.update!(:tool_entry_ids_by_call, &Map.delete(&1, call_id))
    |> upsert_entry_map(entry_id, %{
      id: entry_id,
      kind: :tool,
      body: summarize_command(msg) || "command finished",
      status: status,
      output: summarize_output(Map.get(msg, "aggregated_output") || Map.get(msg, "output"))
    })
  end

  defp apply_notification(state, "thread/tokenUsage/updated", %{"tokenUsage" => usage})
       when is_map(usage) do
    Map.put(state, :token_usage, usage)
  end

  defp apply_notification(state, "account/rateLimits/updated", %{"rateLimits" => limits})
       when is_map(limits) do
    Map.put(state, :rate_limits, limits)
  end

  defp apply_notification(state, "error", params) do
    msg = Map.get(params, "message") || Map.get(params, "error") || inspect(params, limit: 20)
    push_entry(state, :error, "codex error: #{msg}")
  end

  @ignored_methods ~w[
    initialize initialized thread/start turn/start
    item/started item/completed
    item/reasoning/summaryPartAdded item/reasoning/summaryTextDelta
  ]

  defp apply_notification(state, method, _params) when method in @ignored_methods, do: state

  defp apply_notification(state, method, params) do
    if MapSet.member?(state.seen_misc_methods, method) do
      state
    else
      state
      |> Map.update!(:seen_misc_methods, &MapSet.put(&1, method))
      |> push_entry(:status, "received #{method} #{preview(params)}")
    end
  end

  defp safely_apply_notification(state, method, params) do
    apply_notification(state, method, params)
  rescue
    error ->
      Span.execute([:froth, :codex, :notification_failed], nil, %{
        method: method,
        error: Exception.message(error)
      })

      push_entry(state, :error, "failed to process #{method}: #{Exception.message(error)}")
  end

  # --- Entry management ---

  defp push_entry(state, kind, body) when is_atom(kind) and is_binary(body) do
    sequence = state.entry_seq + 1
    entry = %{id: "e-#{sequence}", kind: kind, body: body, sequence: sequence}
    state = %{state | entry_seq: sequence, entries: trim_entries(state.entries ++ [entry])}
    CodexEvents.upsert_entry(state.session_id, entry)
    state
  end

  defp upsert_entry(state, id, kind, body) when is_binary(id) and is_binary(body) do
    upsert_entry_map(state, id, %{id: id, kind: kind, body: body})
  end

  defp upsert_entry_map(state, id, entry) when is_binary(id) and is_map(entry) do
    case Enum.find_index(state.entries, &(&1.id == id)) do
      nil ->
        sequence = state.entry_seq + 1
        entry = Map.merge(entry, %{id: id, sequence: sequence})
        state = %{state | entries: trim_entries(state.entries ++ [entry]), entry_seq: sequence}
        CodexEvents.upsert_entry(state.session_id, entry)
        state

      idx ->
        sequence = (Enum.at(state.entries, idx) || %{})[:sequence] || state.entry_seq + 1
        entry = Map.merge(entry, %{id: id, sequence: sequence})
        state = %{state | entries: List.replace_at(state.entries, idx, entry)}
        CodexEvents.upsert_entry(state.session_id, entry)
        state
    end
  end

  defp trim_entries(entries) do
    overflow = length(entries) - @max_entries
    if overflow > 0, do: Enum.drop(entries, overflow), else: entries
  end

  # --- State helpers ---

  defp reset_turn_state(state) do
    %{
      state
      | active_assistant_entry_id: nil,
        active_assistant_text: "",
        active_reasoning_entry_id: nil,
        active_reasoning_text: "",
        tool_entry_ids_by_call: %{}
    }
  end

  defp snapshot_from_state(state) do
    Map.take(state, [
      :session_id,
      :status,
      :thread_id,
      :active_turn_id,
      :entries,
      :token_usage,
      :rate_limits,
      :auth,
      :runtime
    ])
  end

  defp broadcast_update(state) do
    Froth.broadcast(topic(state.session_id), {:codex_session_updated, state.session_id})

    state
  end

  # --- Auth ---

  defp refresh_auth_status(state) do
    case codex_call(state, :account_read, %{"refreshToken" => false}) do
      {:ok, result} when is_map(result) ->
        account = Map.get(result, "account")

        auth = %{
          authenticated: is_map(account),
          account_type: is_map(account) && Map.get(account, "type"),
          plan_type: is_map(account) && Map.get(account, "planType"),
          email: is_map(account) && Map.get(account, "email"),
          requires_openai_auth: Map.get(result, "requiresOpenaiAuth") == true,
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        state = Map.put(state, :auth, auth)

        if auth.authenticated do
          descriptor =
            [auth.account_type, auth.plan_type, auth.email]
            |> Enum.filter(&(is_binary(&1) and &1 != ""))
            |> Enum.join(" · ")

          push_entry(state, :system, "auth ok #{descriptor}")
        else
          push_entry(state, :status, "auth not available")
        end

      {:error, _} ->
        auth = %{
          authenticated: false,
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        state
        |> Map.put(:auth, auth)
        |> push_entry(:status, "auth probe failed")
    end
  end

  # --- Runtime config ---

  defp refresh_runtime_config(state) do
    case codex_call(state, :config_read, %{}) do
      {:ok, %{"config" => config}} when is_map(config) ->
        merge_runtime(state, %{
          model: Map.get(config, "model"),
          model_provider: Map.get(config, "model_provider"),
          reasoning_effort: Map.get(config, "model_reasoning_effort"),
          approval_policy: Map.get(config, "approval_policy"),
          personality: Map.get(config, "personality"),
          sandbox: Map.get(config, "sandbox_mode")
        })

      _ ->
        state
    end
  end

  defp apply_runtime_patch(state, result, extra \\ %{}) when is_map(result) do
    thread = Map.get(result, "thread") || %{}

    merge_runtime(state, %{
      model: Map.get(result, "model"),
      model_provider: Map.get(result, "modelProvider") || Map.get(thread, "modelProvider"),
      reasoning_effort: Map.get(result, "reasoningEffort"),
      approval_policy: Map.get(result, "approvalPolicy") || Map.get(extra, "approvalPolicy"),
      personality: Map.get(result, "personality") || Map.get(extra, "personality"),
      cwd: Map.get(result, "cwd") || Map.get(thread, "cwd") || Map.get(extra, "cwd"),
      sandbox: summarize_sandbox(Map.get(result, "sandbox") || Map.get(extra, "sandbox")),
      cli_version: Map.get(thread, "cliVersion"),
      source: Map.get(thread, "source")
    })
  end

  defp merge_runtime(state, patch) when is_map(patch) do
    compact = patch |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end) |> Map.new()

    if map_size(compact) == 0 do
      state
    else
      existing = state.runtime || %{}

      runtime =
        existing
        |> Map.merge(compact)
        |> Map.put(:checked_at, DateTime.utc_now() |> DateTime.to_iso8601())

      Map.put(state, :runtime, runtime)
    end
  end

  defp summarize_sandbox(sandbox) when is_binary(sandbox), do: sandbox

  defp summarize_sandbox(sandbox) when is_map(sandbox) do
    ro_type =
      case Map.get(sandbox, "readOnlyAccess") do
        %{"type" => t} when is_binary(t) -> "ro:#{t}"
        _ -> nil
      end

    parts =
      [
        Map.get(sandbox, "type"),
        if(Map.get(sandbox, "networkAccess") == true, do: "net:on"),
        if(Map.get(sandbox, "networkAccess") == false, do: "net:off"),
        ro_type
      ]
      |> Enum.filter(&is_binary/1)

    if parts == [], do: nil, else: Enum.join(parts, " ")
  end

  defp summarize_sandbox(_), do: nil

  # --- ID helpers ---

  defp get_thread_id(%{"thread" => %{"id" => id}}) when is_binary(id), do: id
  defp get_thread_id(%{"threadId" => id}) when is_binary(id), do: id
  defp get_thread_id(_), do: nil

  defp get_turn_id(%{"turn" => %{"id" => id}}) when is_binary(id), do: id
  defp get_turn_id(%{"turnId" => id}) when is_binary(id), do: id
  defp get_turn_id(_), do: nil

  defp make_assistant_id(params) do
    turn = Map.get(params, "turnId", "turn")
    item = Map.get(params, "itemId", "agent")
    "assistant-#{turn}-#{item}"
  end

  defp make_reasoning_id(params) do
    item = Map.get(params, "itemId", "reasoning")
    index = Map.get(params, "summaryIndex", 0)
    "reasoning-#{item}-#{index}"
  end

  defp maybe_track_tool_call(state, call_id, entry_id) when is_binary(call_id) do
    Map.update!(state, :tool_entry_ids_by_call, &Map.put(&1, call_id, entry_id))
  end

  defp maybe_track_tool_call(state, _, _), do: state

  defp upsert_assistant_message(state, turn_id, item_id, text)
       when is_binary(text) and text != "" do
    turn_key = turn_id || "turn"

    assistant_id =
      if is_binary(item_id) and item_id != "" do
        "assistant-#{turn_key}-#{item_id}"
      else
        state.active_assistant_entry_id || "assistant-#{turn_key}-agent"
      end

    state
    |> Map.put(:active_assistant_entry_id, assistant_id)
    |> Map.put(:active_assistant_text, text)
    |> upsert_entry(assistant_id, :assistant, text)
  end

  defp upsert_assistant_message(state, _, _, _), do: state

  defp extract_text_from_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "")
    end
  end

  defp extract_text_from_content(_), do: nil

  # --- Utilities ---

  defp summarize_command(%{"command" => command}) when is_list(command) do
    command |> Enum.map(&to_string/1) |> Enum.join(" ") |> String.trim() |> truncate(220)
  end

  defp summarize_command(%{"parsed_cmd" => [first | _]}) when is_map(first) do
    Map.get(first, "cmd") || Map.get(first, "type")
  end

  defp summarize_command(_), do: nil

  defp summarize_output(output) when is_binary(output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      nil
    else
      lines = String.split(trimmed, "\n")
      truncated = Enum.take(lines, 8) |> Enum.join("\n")
      suffix = if length(lines) > 8, do: "\n...", else: ""
      truncate(truncated <> suffix, 900)
    end
  end

  defp summarize_output(_), do: nil

  defp thread_id_from_opts(opts) do
    case Keyword.get(opts, :thread_id) do
      id when is_binary(id) ->
        trimmed = String.trim(id)
        if String.starts_with?(trimmed, "thr_"), do: trimmed

      _ ->
        nil
    end
  end

  defp client_info(session_id) do
    version =
      case Application.spec(:froth, :vsn) do
        v when is_list(v) -> List.to_string(v)
        v when is_binary(v) -> v
        _ -> "dev"
      end

    %{name: "froth_codex_session_#{session_id}", title: "Froth Codex Session", version: version}
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)

  defp truncate(value, max) when is_binary(value) and is_integer(max) do
    if String.length(value) > max, do: String.slice(value, 0, max) <> "...", else: value
  end

  defp preview(params) when is_map(params) do
    params |> inspect(limit: 12, printable_limit: 180) |> String.slice(0, 180)
  end
end
