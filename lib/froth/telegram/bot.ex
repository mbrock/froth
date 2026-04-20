defmodule Froth.Telegram.Bot do
  @moduledoc """
  Telegram bot runtime backed by `Froth.Agent` cycles.

  Supports mention/reply activation, automatic tool execution, and cycle stop
  controls for Telegram mini-app inspection.
  """

  use GenServer

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Telegram.Bots

  alias Froth.Agent.{
    AwaitControl,
    Config,
    Cycle,
    CycleRuntime,
    FailureIntervention,
    Message,
    ToolResult
  }

  alias Froth.Repo
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.Bot.CycleState
  alias Froth.Telegram.BotAdapter
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.Message, as: TgMessage
  alias Froth.Telegram.MessageIdSync
  alias Froth.Telegram.Names
  alias Froth.Telegram.PendingAsks
  alias Froth.Telegram.PromptCache
  alias Froth.Telemetry.Span

  defstruct [
    :bot_config,
    :cycle_state,
    :runtime_ref,
    debounce_timer: nil,
    debounce_msg: nil,
    pending_ask_resumes: []
  ]

  @game_url "https://1.foo/name-game-3"

  def child_spec(opts) when is_map(opts), do: child_spec(Map.to_list(opts))

  def child_spec(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name, Module.concat(__MODULE__, String.capitalize(id)))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a `CycleRuntime` under the resolved bot's private cycle supervisor.
  """
  @spec start_cycle_runtime(String.t() | pid() | atom() | {:via, module(), term()}, keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, :bot_not_running}
  def start_cycle_runtime(bot_ref, runtime_opts) when is_list(runtime_opts) do
    case resolve(bot_ref) do
      {:ok, pid} ->
        GenServer.call(pid, {:start_cycle_runtime, runtime_opts})

      :error ->
        {:error, :bot_not_running}
    end
  end

  @impl true
  def init(opts) do
    bot_config = BotConfig.build(opts)
    runtime_ref = Keyword.fetch!(opts, :runtime_ref)

    Repo.allow(Froth.Telegram.Session.via(bot_config.session_id), "telegram bot")

    :ok = BotAdapter.subscribe(bot_config.session_id)

    Span.execute(
      [:froth, :telegram, :bot, :listening],
      Froth.Telegram.Session.span_id(bot_config.session_id),
      %{
        bot_id: bot_config.id,
        session_id: bot_config.session_id,
        username: bot_config.bot_username
      }
    )

    {:ok, %__MODULE__{bot_config: bot_config, runtime_ref: runtime_ref}}
  end

  @impl true
  def handle_info(
        {:telegram_update,
         %{
           "@type" => "updateMessageSendSucceeded",
           "old_message_id" => old_id,
           "message" => %{"id" => new_id} = message
         }},
        state
      )
      when is_integer(old_id) and is_integer(new_id) do
    chat_id =
      case message["chat_id"] do
        value when is_integer(value) -> value
        _ -> nil
      end

    if is_integer(chat_id) do
      MessageIdSync.put(state.bot_config.id, chat_id, old_id, new_id)
      PendingAsks.sync_message_id(state.bot_config.id, chat_id, old_id, new_id)
    end

    :ok = CycleRuntime.sync_sent_message_id(old_id, new_id)
    {:noreply, state}
  end

  def handle_info({:telegram_update, update}, state) do
    bc = state.bot_config
    action = route_update(update, bc)

    Span.execute(
      [:froth, :telegram, :bot, :update],
      Froth.Telegram.Session.span_id(bc.session_id),
      %{
        bot_id: bc.id,
        update: update,
        action: action
      }
    )

    {:noreply, dispatch_update_action(state, action)}
  end

  def handle_info(:debounce_fire, state) do
    state = %{state | debounce_timer: nil}

    case state.debounce_msg do
      nil ->
        {:noreply, state}

      msg ->
        state = %{state | debounce_msg: nil}
        {:noreply, start_cycle_from_message(state, msg)}
    end
  end

  def handle_info({:event, _event, %Message{role: :agent, content: content}}, state) do
    {:noreply, send_agent_response(state, content)}
  end

  def handle_info({:event, _event, %Message{}}, state) do
    {:noreply, state}
  end

  def handle_info({:stream, _event}, state), do: {:noreply, state}

  def handle_info({:eval_done_detail, _}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{cycle_state: %CycleState{cycle_runtime_ref: ref, cycle_runtime_pid: pid}} = state
      ) do
    {:noreply,
     state
     |> reset_cycle_state()
     |> maybe_resume_pending_ask()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:start_inference_session, msg}, state) when is_map(msg) do
    {:noreply, start_cycle_from_message(state, msg)}
  end

  def handle_cast({:stop_cycle, cycle_id}, state) when is_binary(cycle_id) do
    {:noreply, stop_cycle(state, cycle_id, notify?: true)}
  end

  def handle_cast({:stop_loop, _inference_session_id}, state) do
    state =
      case state.cycle_state do
        %CycleState{cycle_id: cycle_id} -> stop_cycle(state, cycle_id, notify?: true)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.bot_config, state}
  end

  def handle_call(:runtime_ref, _from, state) do
    {:reply, state.runtime_ref, state}
  end

  def handle_call({:start_cycle_runtime, runtime_opts}, _from, state)
      when is_list(runtime_opts) do
    {:reply, start_cycle_runtime_child(state, runtime_opts), state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, "unsupported"}, state}

  @doc """
  Look up a running Bot and return `{pid, %Froth.Telegram.Bot.Config{}}`.

  `bot_ref` can be a pid, a registered name (module atom or
  `{:via, ...}` tuple). Raises if the bot is not running.
  """
  @spec snapshot(String.t() | pid() | atom() | {:via, module(), term()}) :: {pid(), BotConfig.t()}
  def snapshot(bot_ref) do
    pid =
      case resolve(bot_ref) do
        {:ok, pid} ->
          pid

        :error ->
          raise "bot not running: #{inspect(bot_ref)}"
      end

    {pid, GenServer.call(pid, :snapshot)}
  end

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> :error
    end
  end

  defp resolve(bot_id) when is_binary(bot_id) do
    resolve(Bots.via(bot_id))
  end

  defp resolve({:via, _, _} = via) do
    case GenServer.whereis(via) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> :error
    end
  end

  defp dispatch_update_action(state, {:mention, msg}) do
    debounce_or_start(state, msg)
  end

  defp dispatch_update_action(state, {:pending_ask_answer, pending_ask, answer, reply_to}) do
    enqueue_or_resume_pending_ask(state, pending_ask, answer, reply_to)
  end

  defp dispatch_update_action(state, {:callback_stop_cycle, query_id, cycle_id}) do
    BotAdapter.answer_callback(state.bot_config.session_id, query_id)
    stop_cycle(state, cycle_id, notify?: true)
  end

  defp dispatch_update_action(state, {:callback_stop_active, query_id}) do
    BotAdapter.answer_callback(state.bot_config.session_id, query_id)

    case state.cycle_state do
      %CycleState{cycle_id: cycle_id} -> stop_cycle(state, cycle_id, notify?: true)
      _ -> state
    end
  end

  defp dispatch_update_action(state, {:callback_game, query_id, _game_short_name}) do
    BotAdapter.answer_callback_with_url(state.bot_config.session_id, query_id, @game_url)
    state
  end

  defp dispatch_update_action(
         state,
         {:callback_pending_ask, query_id, pending_ask, answer, reply_to}
       ) do
    BotAdapter.answer_callback(state.bot_config.session_id, query_id)
    enqueue_or_resume_pending_ask(state, pending_ask, answer, reply_to)
  end

  defp dispatch_update_action(state, {:callback_pending_ask_ignored, query_id}) do
    BotAdapter.answer_callback(state.bot_config.session_id, query_id)
    state
  end

  defp dispatch_update_action(state, :ignore), do: state

  defp route_update(%{"@type" => "updateNewMessage", "message" => msg}, bot_config)
       when is_map(msg) do
    sender = TgMessage.sender_user_id(msg)
    chat_id = TgMessage.chat_id(msg)

    is_reply_to_bot = replied_to_bot?(msg, bot_config.bot_user_id)

    mentioned? =
      BotAdapter.mentioned?(
        msg,
        bot_config.bot_username,
        bot_config.bot_user_id,
        bot_config.name_triggers
      )

    allowed_chat? =
      is_integer(chat_id) and
        BotAdapter.allowed_chat?(chat_id, bot_config.owner_user_id, bot_config.session_id)

    cond do
      sender == bot_config.bot_user_id ->
        :ignore

      not allowed_chat? ->
        :ignore

      pending_ask = pending_ask_for_message(msg, bot_config, mentioned?, is_reply_to_bot) ->
        answer = pending_ask_answer_from_message(msg, bot_config)
        reply_to = msg["id"]

        if is_binary(answer) and answer != "" and pending_ask_accepts_message_answer?(pending_ask) do
          case PendingAsks.resolve(pending_ask, answer,
                 answer_message_id: msg["id"],
                 answered_via: "message",
                 config_merge: resolution_config_for_message(msg, bot_config, pending_ask, answer)
               ) do
            {:ok, resolved_pending_ask} ->
              {:pending_ask_answer, resolved_pending_ask, answer, reply_to}

            {:error, _reason} ->
              :ignore
          end
        else
          :ignore
        end

      # DMs (positive chat_id) skip mention check — every message is addressed to us
      chat_id > 0 or mentioned? or is_reply_to_bot ->
        {:mention, msg}

      true ->
        :ignore
    end
  end

  defp route_update(%{"@type" => "updateNewCallbackQuery"} = query, bot_config) do
    route_callback_query(query, bot_config)
  end

  defp route_update(_, _), do: :ignore

  defp route_callback_query(query, bot_config) do
    query_id = query["id"]

    cond do
      is_nil(query_id) ->
        :ignore

      match?(%{"payload" => %{"@type" => "callbackQueryPayloadGame"}}, query) ->
        %{"payload" => %{"game_short_name" => game}} = query
        {:callback_game, query_id, game}

      true ->
        route_callback_data(query, query_id, bot_config)
    end
  end

  defp route_callback_data(query, query_id, bot_config) do
    case parse_callback_payload(query) do
      {:ok, "ask", index} ->
        with chat_id when is_integer(chat_id) <- TgMessage.chat_id(query),
             message_id when is_integer(message_id) <- TgMessage.message_id(query),
             %{} = pending_ask <-
               PendingAsks.get_unresolved_by_message(bot_config.id, chat_id, message_id),
             alternative when is_binary(alternative) <-
               Enum.at(pending_ask.alternatives || [], index),
             {:ok, resolved_pending_ask} <-
               PendingAsks.resolve(pending_ask, alternative,
                 answered_via: "callback",
                 config_merge:
                   resolution_config_for_callback(query, bot_config, pending_ask, alternative,
                     index: index
                   )
               ) do
          {:callback_pending_ask, query_id, resolved_pending_ask, alternative, message_id}
        else
          _ -> {:callback_pending_ask_ignored, query_id}
        end

      {:ok, action, _} when action in ["askcarry", "askstop"] ->
        answer =
          case action do
            "askcarry" -> FailureIntervention.carry_on_answer()
            "askstop" -> FailureIntervention.stop_answer()
          end

        with chat_id when is_integer(chat_id) <- TgMessage.chat_id(query),
             message_id when is_integer(message_id) <- TgMessage.message_id(query),
             %{} = pending_ask <-
               PendingAsks.get_unresolved_by_message(bot_config.id, chat_id, message_id),
             true <- FailureIntervention.failure_intervention?(pending_ask),
             {:ok, resolved_pending_ask} <-
               PendingAsks.resolve(pending_ask, answer,
                 answered_via: "callback",
                 config_merge:
                   resolution_config_for_callback(query, bot_config, pending_ask, answer)
               ) do
          {:callback_pending_ask, query_id, resolved_pending_ask, answer, message_id}
        else
          _ -> {:callback_pending_ask_ignored, query_id}
        end

      {:ok, "stopcycle", cycle_id} when is_binary(cycle_id) ->
        {:callback_stop_cycle, query_id, cycle_id}

      {:ok, "stoploop", _} ->
        {:callback_stop_active, query_id}

      _ ->
        :ignore
    end
  end

  defp parse_callback_payload(%{
         "payload" => %{"@type" => "callbackQueryPayloadData", "data" => data_b64}
       }) do
    with {:ok, data} <- Base.decode64(data_b64) do
      case String.split(data, ":", parts: 2) do
        ["ask", index] ->
          case Integer.parse(index) do
            {parsed_index, ""} when parsed_index >= 0 -> {:ok, "ask", parsed_index}
            _ -> :error
          end

        [action, arg] when action in ["stopcycle", "stoploop", "askcarry", "askstop"] ->
          {:ok, action, arg}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp parse_callback_payload(_), do: :error

  defp pending_ask_for_message(msg, bot_config, mentioned?, is_reply_to_bot)
       when is_map(msg) and is_map(bot_config) do
    chat_id = msg["chat_id"]

    cond do
      reply_message_id = TgMessage.reply_to_message_id(msg) ->
        PendingAsks.get_unresolved_by_message(bot_config.id, chat_id, reply_message_id)

      (is_integer(chat_id) and chat_id > 0) or mentioned? or is_reply_to_bot ->
        case PendingAsks.latest_unresolved(bot_config.id, chat_id) do
          %{} = pending_ask ->
            if FailureIntervention.reply_required?(pending_ask), do: nil, else: pending_ask

          other ->
            other
        end

      true ->
        nil
    end
  end

  defp pending_ask_for_message(_msg, _bot_config, _mentioned?, _is_reply_to_bot), do: nil

  defp pending_ask_accepts_message_answer?(pending_ask) do
    AwaitControl.accepts_message_answer?(pending_ask)
  end

  defp pending_ask_answer_from_message(msg, bot_config) do
    strip_bot_mention(TgMessage.text(msg), bot_config.bot_username)
  end

  defp strip_bot_mention(text, bot_username) when is_binary(text) and is_binary(bot_username) do
    text
    |> String.trim()
    |> String.replace(~r/^@#{Regex.escape(bot_username)}[,:]?\s*/iu, "")
    |> String.trim()
    |> case do
      "" -> nil
      answer -> answer
    end
  end

  defp strip_bot_mention(_text, _bot_username), do: nil

  defp replied_to_bot?(msg, bot_user_id) when is_map(msg) and is_integer(bot_user_id) do
    case msg do
      %{
        "reply_to" => %{
          "@type" => "messageReplyToMessage",
          "message_id" => reply_msg_id,
          "chat_id" => chat_id
        }
      }
      when is_integer(reply_msg_id) and is_integer(chat_id) ->
        Repo.exists?(
          from(m in "telegram_messages",
            where:
              m.chat_id == ^chat_id and m.message_id == ^reply_msg_id and
                m.sender_id == ^bot_user_id
          )
        )

      _ ->
        false
    end
  end

  defp replied_to_bot?(_, _), do: false

  # --- Debounce ---

  defp debounce_or_start(state, msg) do
    debounce_ms = state.bot_config.debounce_ms

    if debounce_ms > 0 and is_nil(state.cycle_state) do
      # Cancel existing timer if any
      if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)

      timer = Process.send_after(self(), :debounce_fire, debounce_ms)
      %{state | debounce_timer: timer, debounce_msg: msg}
    else
      # No debounce or already in a cycle — fire immediately
      start_cycle_from_message(state, msg)
    end
  end

  defp start_cycle_from_message(state, msg) when is_map(msg) do
    chat_id = msg["chat_id"]
    reply_to = msg["reply_to_override"] || msg["id"]
    system_prompt = resolve_system_prompt(chat_id, msg, state.bot_config)

    text = TgMessage.text(msg) || ""

    user_content =
      case BotContext.for_message(msg, state.bot_config) do
        nil -> nil
        parts -> parts_to_text_blocks(parts, state.bot_config)
      end

    start_cycle(state, chat_id, reply_to, text, user_content, system_prompt)
  end

  defp start_cycle(state, chat_id, reply_to, text, user_content, system_prompt)
       when is_integer(chat_id) and (is_integer(reply_to) or is_nil(reply_to)) and
              is_binary(text) and is_binary(system_prompt) do
    bc = state.bot_config

    # Per RFC-0021 step 3: every inbound user message starts its own
    # root cycle. Parallel cycles in the same chat are allowed and
    # expected; the Bot's `cycle_state` just tracks the most recent
    # one for DOWN/stop-active dispatch. Older cycles keep running
    # under their own `CycleRuntime` registered in `CycleRegistry`.
    BotAdapter.send_typing(bc.session_id, chat_id)

    initial_content =
      if is_nil(user_content) do
        text
      else
        user_content
      end

    message =
      Repo.insert!(%Message{
        role: :user,
        content: Message.wrap(initial_content)
      })

    base_config = %Config{
      system: system_prompt,
      model: bc.model,
      tools: resolve_tool_specs(bc),
      tool_executor: self(),
      context: %{
        chat_id: chat_id,
        reply_to: reply_to,
        bot_id: bc.id,
        session_id: bc.session_id,
        bot_username: bc.bot_username
      },
      thinking: bc.thinking,
      effort: bc.effort
    }

    cycle = Agent.begin_cycle(message, base_config)

    Repo.insert!(%CycleLink{
      cycle_id: cycle.id,
      bot_id: bc.id,
      chat_id: chat_id,
      reply_to: reply_to
    })

    launch_cycle_worker(state, cycle, base_config, chat_id, reply_to)
  end

  defp start_cycle(state, _chat_id, _reply_to, _text, _user_content, _system_prompt), do: state

  defp launch_cycle_worker(
         state,
         %Cycle{} = cycle,
         %Config{} = config,
         chat_id,
         reply_to
       )
       when is_integer(chat_id) and (is_integer(reply_to) or is_nil(reply_to)) do
    bc = state.bot_config
    session_span = Froth.Telegram.Session.span_id(bc.session_id)

    cycle =
      Agent.update_cycle(cycle, %{
        parent_span_id: session_span,
        config: Map.put(cycle.config || %{}, "parent_span_id", session_span)
      })

    config = %{config | parent_span_id: session_span}

    Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle.id}")

    runtime_opts = [
      cycle_id: cycle.id,
      cycle: cycle,
      worker_config: config,
      bot_id: bc.id,
      bot_config: bc,
      bot_pid: self(),
      chat_id: chat_id,
      reply_to: reply_to
    ]

    {:ok, runtime_pid} = start_cycle_runtime_child(state, runtime_opts)

    ref = Process.monitor(runtime_pid)

    %{
      state
      | cycle_state: %CycleState{
          cycle_id: cycle.id,
          cycle_runtime_pid: runtime_pid,
          cycle_runtime_ref: ref,
          chat_id: chat_id,
          reply_to: reply_to
        }
    }
  end

  defp start_cycle_runtime_child(state, runtime_opts) when is_list(runtime_opts) do
    runtime_opts =
      runtime_opts
      |> Keyword.put_new(:bot_id, state.bot_config.id)
      |> Keyword.put_new(:bot_config, state.bot_config)
      |> Keyword.put_new(:bot_pid, self())

    case cycles_sup(state.runtime_ref) do
      pid when is_pid(pid) ->
        DynamicSupervisor.start_child(pid, {CycleRuntime, runtime_opts})

      _ ->
        {:error, :bot_not_running}
    end
  end

  defp cycles_sup(runtime_ref) when is_pid(runtime_ref) do
    case Supervisor.which_children(runtime_ref) do
      children when is_list(children) ->
        Enum.find_value(children, fn
          {:cycles_sup, pid, _type, _modules} when is_pid(pid) -> pid
          _ -> nil
        end)

      _ ->
        nil
    end
  catch
    :exit, _reason -> nil
  end

  @response_instruction "\n\nNow reply using the send_message tool."

  defp parts_to_text_blocks(parts, bot_config) when is_list(parts) do
    parts
    |> maybe_append_response_instruction(bot_config)
    |> PromptCache.text_blocks(bot_config)
  end

  defp maybe_append_response_instruction(parts, bot_config) do
    if send_message_tool_enabled?(bot_config) do
      append_response_instruction(parts)
    else
      parts
    end
  end

  defp append_response_instruction([]), do: [String.trim(@response_instruction)]

  defp append_response_instruction(parts) do
    {last, rest} = List.pop_at(parts, -1)
    rest ++ [last <> @response_instruction]
  end

  defp stop_cycle(state, cycle_id, opts) when is_binary(cycle_id) do
    notify? = Keyword.get(opts, :notify?, false)
    cs = state.cycle_state

    active? = match?(%CycleState{cycle_id: ^cycle_id}, cs)

    if notify? and active? do
      BotAdapter.send_italic(state.bot_config.session_id, cs.chat_id, cs.reply_to, "stopped")
    end

    # Capture task ids before terminating the runtime; once it's dead,
    # its `active_tasks` state is gone along with its Registry entry.
    task_ids = if active?, do: CycleRuntime.active_task_ids(cycle_id), else: []

    state =
      if active? do
        Process.exit(cs.cycle_runtime_pid, {:shutdown, :cancelled})
        reset_cycle_state(state)
      else
        state
      end

    Enum.each(task_ids, &stop_background_task/1)
    state
  end

  # Clear `cycle_state` — back to "idle". The runtime process is assumed
  # to be terminating or already gone; background task bookkeeping lived
  # on it and goes with it.
  defp reset_cycle_state(state), do: %{state | cycle_state: nil}

  defp maybe_resume_pending_ask(%{pending_ask_resumes: []} = state), do: state

  defp maybe_resume_pending_ask(%{pending_ask_resumes: [resume | rest]} = state) do
    state
    |> Map.put(:pending_ask_resumes, rest)
    |> resume_pending_ask(resume)
  end

  defp maybe_finalize_pending_ask_message(pending_ask, session_id) do
    cond do
      FailureIntervention.failure_intervention?(pending_ask) ->
        FailureIntervention.maybe_finalize_message(pending_ask, session_id)

      AwaitControl.await?(pending_ask) ->
        AwaitControl.maybe_finalize_message(pending_ask, session_id)

      true ->
        :ok
    end
  end

  defp enqueue_or_resume_pending_ask(state, pending_ask, answer, reply_to)
       when is_map(pending_ask) and is_binary(answer) do
    _ = maybe_finalize_pending_ask_message(pending_ask, state.bot_config.session_id)
    resume = %{pending_ask: pending_ask, answer: answer, reply_to: reply_to}

    cond do
      live_pending_ask_cycle?(state, pending_ask) ->
        resolve_pending_ask_live(state, resume)

      state.cycle_state ->
        %{state | pending_ask_resumes: state.pending_ask_resumes ++ [resume]}

      true ->
        resume_pending_ask(state, resume)
    end
  end

  defp resume_pending_ask(
         state,
         %{pending_ask: pending_ask, answer: answer, reply_to: reply_to}
       )
       when is_map(pending_ask) and is_binary(answer) do
    case pending_ask_resolution(pending_ask) do
      {:stop_cycle, mode} ->
        stop_pending_ask_cycle(state, pending_ask, mode)

      {:tool_result, %ToolResult{} = tool_result} ->
        with %Cycle{} = cycle <- Repo.get(Cycle, pending_ask.cycle_id),
             %Config{} = config <- pending_ask_worker_config(state, pending_ask, reply_to),
             {_message, _head_id} <-
               Agent.append_message(
                 cycle,
                 Agent.latest_head_id(cycle),
                 :user,
                 [ToolResult.to_api(tool_result)]
               ) do
          BotAdapter.send_typing(state.bot_config.session_id, pending_ask.chat_id)

          launch_cycle_worker(
            clear_pending_ask_wait(state),
            cycle,
            config,
            pending_ask.chat_id,
            reply_to || pending_ask.message_id
          )
        else
          _ ->
            state
        end
    end
  end

  defp resolve_pending_ask_live(
         %{cycle_state: %CycleState{cycle_runtime_pid: runtime_pid}} = state,
         %{pending_ask: pending_ask}
       )
       when is_map(pending_ask) do
    case pending_ask_resolution(pending_ask) do
      {:stop_cycle, mode} ->
        state = stop_pending_ask_tasks(state, pending_ask, mode)
        state = clear_pending_ask_wait(state)

        try do
          _ =
            CycleRuntime.resolve_pending_ask(
              runtime_pid,
              pending_ask.id,
              {:stop, {:shutdown, mode}}
            )

          state
        catch
          :exit, _reason ->
            stop_pending_ask_cycle(state, pending_ask, mode)
        end

      {:tool_result, %ToolResult{} = tool_result} ->
        BotAdapter.send_typing(state.bot_config.session_id, pending_ask.chat_id)
        state = clear_pending_ask_wait(state)

        try do
          case CycleRuntime.resolve_pending_ask(
                 runtime_pid,
                 pending_ask.id,
                 {:tool_result, tool_result}
               ) do
            :ok -> state
            # Only way the worker replies with an error is an invalid resolution,
            # which we can't construct from here. Leave state untouched.
            {:error, _reason} -> state
          end
        catch
          :exit, _reason ->
            resume_pending_ask(state, %{
              pending_ask: pending_ask,
              answer: pending_ask.answer || "",
              reply_to: pending_ask.answer_message_id
            })
        end
    end
  end

  defp live_pending_ask_cycle?(
         %{cycle_state: %CycleState{cycle_id: cycle_id}},
         pending_ask
       )
       when is_binary(cycle_id) do
    pending_ask.cycle_id == cycle_id
  end

  defp live_pending_ask_cycle?(_state, _pending_ask), do: false

  defp pending_ask_resolution(pending_ask) do
    cond do
      FailureIntervention.failure_intervention?(pending_ask) ->
        case FailureIntervention.resume_tool_result(pending_ask) do
          :stop -> {:stop_cycle, :stop}
          tool_result -> {:tool_result, api_tool_result(tool_result, pending_ask.tool_use_id)}
        end

      AwaitControl.await?(pending_ask) ->
        case AwaitControl.tool_resolution(pending_ask) do
          {:stop_cycle, mode} ->
            {:stop_cycle, mode}

          {:tool_result, content} ->
            {:tool_result, ToolResult.new(pending_ask.tool_use_id, content)}
        end

      true ->
        {:tool_result, ToolResult.new(pending_ask.tool_use_id, pending_ask.answer || "")}
    end
  end

  defp api_tool_result(
         %{
           "type" => "tool_result",
           "tool_use_id" => tool_use_id,
           "content" => content
         } = result,
         _fallback_tool_use_id
       ) do
    ToolResult.new(tool_use_id, content, is_error: result["is_error"] == true)
  end

  defp api_tool_result(_other, tool_use_id), do: ToolResult.new(tool_use_id, "")

  defp stop_pending_ask_cycle(state, %{cycle_id: cycle_id} = pending_ask, mode)
       when is_binary(cycle_id) do
    state =
      state
      |> stop_pending_ask_tasks(pending_ask, mode)
      |> clear_pending_ask_wait()

    _ =
      case Repo.get(Cycle, cycle_id) do
        %Cycle{} = cycle ->
          Agent.update_cycle(cycle, %{
            status: :cancelled,
            finished_at: DateTime.utc_now(),
            error: nil
          })

        _ ->
          nil
      end

    state
  end

  defp stop_pending_ask_cycle(state, _pending_ask, _mode), do: state

  defp stop_pending_ask_tasks(state, pending_ask, mode) do
    task_ids = CycleRuntime.active_task_ids(pending_ask.cycle_id)

    case mode do
      :cancel ->
        Enum.each(task_ids, &stop_background_task/1)
        state

      :detach ->
        Enum.each(task_ids, fn task_id ->
          Froth.Tasks.subscribe_telegram(task_id, state.bot_config.id, pending_ask.chat_id,
            message_id: AwaitControl.reply_to(pending_ask)
          )
        end)

        state

      _ ->
        state
    end
  end

  defp clear_pending_ask_wait(%{cycle_state: nil} = state), do: state

  defp clear_pending_ask_wait(state) do
    case state.cycle_state do
      %CycleState{cycle_id: cycle_id} ->
        :ok = CycleRuntime.clear_awaiting_user_input(cycle_id)
        state

      _ ->
        state
    end
  end

  defp resolution_config_for_message(msg, bot_config, pending_ask, answer)
       when is_map(msg) and is_map(bot_config) do
    actor_id = TgMessage.sender_user_id(msg)

    answer
    |> resolution_config_base(bot_config, pending_ask, actor_id)
    |> Map.merge(
      pending_ask_resolution_config(pending_ask, answer,
        source: :message,
        custom?: FailureIntervention.failure_intervention?(pending_ask),
        actor_id: actor_id,
        actor_label: resolution_actor_label(actor_id, bot_config),
        index: resolution_index_for_answer(pending_ask, answer)
      )
    )
  end

  defp resolution_config_for_message(_msg, _bot_config, _pending_ask, _answer), do: %{}

  defp resolution_config_for_callback(query, bot_config, pending_ask, answer, opts \\ [])
       when is_map(query) and is_map(bot_config) and is_list(opts) do
    actor_id = TgMessage.sender_user_id(query)

    answer
    |> resolution_config_base(bot_config, pending_ask, actor_id)
    |> Map.merge(
      pending_ask_resolution_config(pending_ask, answer,
        source: :callback,
        actor_id: actor_id,
        actor_label: resolution_actor_label(actor_id, bot_config),
        index: Keyword.get(opts, :index)
      )
    )
  end

  defp resolution_config_base(_answer, _bot_config, pending_ask, _actor_id) do
    if AwaitControl.await?(pending_ask) do
      %{"resolution" => %{}}
    else
      %{}
    end
  end

  defp pending_ask_resolution_config(pending_ask, answer, opts) do
    if AwaitControl.await?(pending_ask) do
      actor_label = Keyword.get(opts, :actor_label)

      %{
        "resolution" =>
          %{}
          |> maybe_put_resolution_value("source", pending_ask_resolution_source(opts[:source]))
          |> maybe_put_resolution_value("actor_id", opts[:actor_id])
          |> maybe_put_resolution_value("actor_label", actor_label)
      }
    else
      FailureIntervention.resolution_config(answer, opts)
    end
  end

  defp maybe_put_resolution_value(map, _key, nil), do: map
  defp maybe_put_resolution_value(map, key, value), do: Map.put(map, key, value)

  defp pending_ask_resolution_source(source) when source in [:message, :callback],
    do: Atom.to_string(source)

  defp pending_ask_resolution_source(_source), do: nil

  defp resolution_actor_label(actor_id, %{session_id: session_id})
       when is_integer(actor_id) and is_binary(session_id) do
    Names.sender_label(actor_id, session_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp resolution_actor_label(_actor_id, _bot_config), do: nil

  defp resolution_index_for_answer(pending_ask, answer)
       when is_map(pending_ask) and is_binary(answer) do
    Enum.find_index(pending_ask.alternatives || [], &(&1 == answer))
  end

  defp stop_background_task(task_id) when is_binary(task_id) do
    cond do
      String.starts_with?(task_id, "eval:") ->
        _ = Froth.Tasks.Eval.stop_eval(task_id)

      String.starts_with?(task_id, "shell:") ->
        if Froth.Tasks.Shell.alive?(task_id) do
          _ = Froth.Tasks.Shell.send_signal(task_id, "TERM")
        end

      true ->
        :ok
    end

    case Froth.Tasks.get(task_id) do
      %{status: status} when status in ["pending", "running"] ->
        _ = Froth.Tasks.stop(task_id)

      _ ->
        :ok
    end
  end

  defp stop_background_task(_), do: :ok

  defdelegate resolve_system_prompt(chat_id, msg, bot_config), to: BotConfig

  defp send_agent_response(
         %{cycle_state: %CycleState{chat_id: chat_id, reply_to: reply_to}, bot_config: bc} = state,
         content
       )
       when is_integer(chat_id) do
    case String.trim(extract_text(content)) do
      "" ->
        state

      text ->
        send_plaintext_response(state, bc.session_id, chat_id, reply_to, text)
    end
  end

  defp send_agent_response(state, _), do: state

  defp send_plaintext_response(state, session_id, chat_id, reply_to, text)
       when is_binary(session_id) and is_integer(chat_id) and is_binary(text) do
    cycle_id =
      case state.cycle_state do
        %CycleState{cycle_id: id} -> id
        _ -> nil
      end

    text
    |> BotAdapter.split_long_text()
    |> Enum.each(fn chunk ->
      case BotAdapter.send_message(session_id, chat_id, chunk, reply_to: reply_to) do
        {:ok, sent} when is_binary(cycle_id) ->
          CycleRuntime.track_sent_message(cycle_id, sent, chunk)

        _ ->
          :ok
      end
    end)

    state
  end

  defp send_message_tool_enabled?(bot_config) when is_map(bot_config) do
    bot_config
    |> resolve_tool_specs()
    |> Enum.any?(&match?(%{"name" => "send_message"}, &1))
  end

  defp send_message_tool_enabled?(_), do: false

  defdelegate resolve_tool_specs(bot_config), to: BotConfig

  defp pending_ask_worker_config(state, pending_ask, reply_to)
       when is_map(pending_ask) do
    bc = state.bot_config

    %Config{
      system: resolve_system_prompt(pending_ask.chat_id, nil, bc),
      model: bc.model,
      tools: resolve_tool_specs(bc),
      tool_executor: self(),
      context: %{
        chat_id: pending_ask.chat_id,
        reply_to: reply_to || pending_ask.message_id,
        bot_id: bc.id,
        session_id: bc.session_id,
        bot_username: bc.bot_username
      },
      thinking: bc.thinking,
      effort: bc.effort
    }
  end

  defp extract_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(_), do: ""
end
