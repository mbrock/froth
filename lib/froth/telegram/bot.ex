defmodule Froth.Telegram.Bot do
  @moduledoc """
  Telegram bot runtime backed by `Froth.Agent` cycles.

  Supports mention/reply activation, automatic tool execution, and cycle stop
  controls for Telegram mini-app inspection.
  """

  use GenServer

  import Ecto.Query

  alias Froth.Agent

  alias Froth.Agent.{
    AwaitControl,
    Config,
    Cycle,
    FailureIntervention,
    Message,
    ToolResult,
    ToolUse,
    Worker
  }

  alias Froth.Repo
  alias Froth.Telegram.BotAdapter
  alias Froth.Telegram.BotContext
  alias Froth.Telegram.ControlPrompt
  alias Froth.Telegram.CycleLink
  alias Froth.Telegram.MessageIdSync
  alias Froth.Telegram.Names
  alias Froth.Telegram.PendingAsks
  alias Froth.Telegram.PromptCache
  alias Froth.Telegram.SyntheticMessage
  alias Froth.Telegram.ToolExecution
  alias Froth.Telemetry.Span

  defstruct [
    :bot_config,
    :cycle,
    :worker_pid,
    :worker_ref,
    :chat_id,
    :reply_to,
    :last_sent_message_id,
    :last_sent_message_text,
    :current_narration_message_id,
    :current_narration_text,
    :current_narration_mode,
    active_tasks: %{},
    control_prompt_cycles: MapSet.new(),
    awaiting_user_input?: false,
    debounce_timer: nil,
    debounce_msg: nil,
    mid_cycle_messages: [],
    pending_ask_resumes: []
  ]

  @telegram_text_limit 4096
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

  @impl true
  def init(opts) do
    bot_config = %{
      id: to_string(Keyword.fetch!(opts, :id)),
      session_id: to_string(Keyword.fetch!(opts, :session_id)),
      bot_username: to_string(Keyword.fetch!(opts, :bot_username)),
      bot_user_id: Keyword.fetch!(opts, :bot_user_id),
      owner_user_id: Keyword.fetch!(opts, :owner_user_id),
      model: Keyword.get(opts, :model, "claude-opus-4-6"),
      system_prompt:
        Keyword.get(opts, :system_prompt, "You are a helpful assistant on Telegram."),
      system_prompt_fun: Keyword.get(opts, :system_prompt_fun),
      name_triggers: Keyword.get(opts, :name_triggers, []),
      tools: Keyword.get(opts, :tools),
      tools_module: Keyword.get(opts, :tools_module),
      thinking: Keyword.get(opts, :thinking),
      effort: Keyword.get(opts, :effort),
      chronicle_dir: Keyword.get(opts, :chronicle_dir),
      recent_message_limit: Keyword.get(opts, :recent_message_limit),
      recent_message_anchor_size: Keyword.get(opts, :recent_message_anchor_size),
      debounce_ms: Keyword.get(opts, :debounce_ms, 0)
    }

    :ok = BotAdapter.subscribe(bot_config.session_id)

    session_span = Froth.Telegram.Session.span_id(bot_config.session_id)

    Span.execute([:froth, :telegram, :bot, :listening], session_span, %{
      bot_id: bot_config.id,
      session_id: bot_config.session_id,
      username: bot_config.bot_username
    })

    {:ok, %__MODULE__{bot_config: bot_config}}
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

    {:noreply, sync_sent_message_id(state, old_id, new_id)}
  end

  def handle_info({:telegram_update, update}, state) do
    update_type = update["@type"] || "unknown"
    bc = state.bot_config
    session_span = Froth.Telegram.Session.span_id(bc.session_id)
    chat_id = update_chat_id(update)
    sender_id = update_sender_id(update)
    text = update_text(update)

    case route_update(update, bc) do
      {:mention, msg} ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "mention",
          chat_id: chat_id,
          sender_id: sender_id,
          message_id: msg["id"],
          text: String.slice(text || "", 0, 200)
        })

        {:noreply, debounce_or_start(state, msg)}

      {:pending_ask_answer, pending_ask, answer, reply_to} ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "pending_ask_answer",
          chat_id: chat_id,
          pending_ask_id: pending_ask.id
        })

        {:noreply, enqueue_or_resume_pending_ask(state, pending_ask, answer, reply_to)}

      {:callback_stop_cycle, query_id, cycle_id} ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "callback_stop_cycle",
          cycle_id: cycle_id
        })

        BotAdapter.answer_callback(bc.session_id, query_id)
        {:noreply, stop_cycle(state, cycle_id, notify?: true)}

      {:callback_stop_active, query_id} ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "callback_stop_active"
        })

        BotAdapter.answer_callback(bc.session_id, query_id)

        state =
          case state.cycle do
            %Cycle{id: cycle_id} -> stop_cycle(state, cycle_id, notify?: true)
            _ -> state
          end

        {:noreply, state}

      {:callback_game, query_id, game_short_name} ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "callback_game",
          game: game_short_name
        })

        _ = game_short_name
        BotAdapter.answer_callback_with_url(bc.session_id, query_id, @game_url)
        {:noreply, state}

      {:callback_pending_ask, query_id, pending_ask, answer, reply_to} ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "callback_pending_ask",
          chat_id: chat_id,
          pending_ask_id: pending_ask.id
        })

        BotAdapter.answer_callback(bc.session_id, query_id)
        {:noreply, enqueue_or_resume_pending_ask(state, pending_ask, answer, reply_to)}

      {:callback_pending_ask_ignored, query_id} ->
        BotAdapter.answer_callback(bc.session_id, query_id)
        {:noreply, state}

      :ignore ->
        Span.execute([:froth, :telegram, :bot, :update], session_span, %{
          bot_id: bc.id,
          update_type: update_type,
          action: "ignore",
          chat_id: chat_id,
          sender_id: sender_id
        })

        {:noreply, state}
    end
  end

  @impl true
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
    state = normalize_state(state)
    {:noreply, send_agent_response(state, content)}
  end

  def handle_info({:event, _event, %Message{}}, state) do
    {:noreply, state}
  end

  def handle_info({:stream, _event}, state), do: {:noreply, state}

  def handle_info({:eval_done_detail, _}, state) do
    {:noreply, state}
  end

  def handle_info({:register_cycle_task, cycle_id, task_id}, state)
      when is_binary(cycle_id) and is_binary(task_id) do
    tasks =
      Map.update(state.active_tasks, cycle_id, MapSet.new([task_id]), &MapSet.put(&1, task_id))

    {:noreply, %{state | active_tasks: tasks}}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{worker_ref: ref, worker_pid: pid} = state
      ) do
    state = normalize_state(state)
    buffered_messages = state.mid_cycle_messages
    finished_cycle_id = state.cycle && state.cycle.id

    state = maybe_append_cycle_footer(state)

    {:noreply,
     state
     |> reset_cycle_state()
     |> prune_cycle_indexes(finished_cycle_id)
     |> maybe_resume_pending_ask()
     |> maybe_resume_buffered_cycle(buffered_messages)}
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
      case state.cycle do
        %Cycle{id: cycle_id} -> stop_cycle(state, cycle_id, notify?: true)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_call({:prepare_tool, %ToolUse{} = tool_use, context}, _from, state) do
    {reply, state} = prepare_tool_call(state, tool_use, context)
    {:reply, reply, state}
  end

  def handle_call({:commit_tool, %ToolUse{} = tool_use, context, prepared, outcome}, _from, state) do
    {reply, state} = commit_tool_call(state, tool_use, context, prepared, outcome)
    {:reply, reply, state}
  end

  def handle_call({:execute, %ToolUse{} = tool_use, context}, _from, state) do
    {reply, state} = prepare_tool_call(state, tool_use, context)

    {result, state} =
      case reply do
        {:ok, prepared} ->
          outcome = ToolExecution.execute(prepared.execution)
          commit_tool_call(state, tool_use, context, prepared, outcome)

        {:error, reason} ->
          {{:error, reason}, state}
      end

    {:reply, result, state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, "unsupported"}, state}

  defp route_update(%{"@type" => "updateNewMessage", "message" => msg}, bot_config)
       when is_map(msg) do
    sender = get_in(msg, ["sender_id", "user_id"])
    chat_id = msg["chat_id"]

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
        answer = normalize_pending_ask_answer(msg, bot_config)
        reply_to = normalize_reply_to(msg["id"])

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

  defp update_chat_id(%{"message" => %{"chat_id" => chat_id}}) when is_integer(chat_id),
    do: chat_id

  defp update_chat_id(_), do: nil

  defp update_sender_id(%{"message" => %{"sender_id" => %{"user_id" => sender_id}}})
       when is_integer(sender_id),
       do: sender_id

  defp update_sender_id(_), do: nil

  defp update_text(%{"message" => %{"content" => %{"text" => %{"text" => text}}}})
       when is_binary(text),
       do: text

  defp update_text(%{"message" => %{"content" => %{"caption" => %{"text" => text}}}})
       when is_binary(text),
       do: text

  defp update_text(_), do: nil

  defp route_callback_query(query, bot_config) do
    query_id = callback_query_id(query)

    case query do
      %{"payload" => %{"@type" => "callbackQueryPayloadGame", "game_short_name" => game}}
      when is_binary(query_id) ->
        {:callback_game, query_id, game}

      _ ->
        case parse_callback_payload(query) do
          {:ok, "ask", index} when is_binary(query_id) ->
            with chat_id when is_integer(chat_id) <- callback_query_chat_id(query),
                 message_id when is_integer(message_id) <- callback_query_message_id(query),
                 %{} = pending_ask <-
                   PendingAsks.get_unresolved_by_message(bot_config.id, chat_id, message_id),
                 alternative when is_binary(alternative) <-
                   Enum.at(pending_ask.alternatives || [], index),
                 {:ok, resolved_pending_ask} <-
                   PendingAsks.resolve(pending_ask, alternative,
                     answered_via: "callback",
                     config_merge:
                       resolution_config_for_callback(
                         query,
                         bot_config,
                         pending_ask,
                         alternative,
                         index: index
                       )
                   ) do
              {:callback_pending_ask, query_id, resolved_pending_ask, alternative, message_id}
            else
              _ -> {:callback_pending_ask_ignored, query_id}
            end

          {:ok, "askcarry", _} when is_binary(query_id) ->
            with chat_id when is_integer(chat_id) <- callback_query_chat_id(query),
                 message_id when is_integer(message_id) <- callback_query_message_id(query),
                 %{} = pending_ask <-
                   PendingAsks.get_unresolved_by_message(bot_config.id, chat_id, message_id),
                 true <- FailureIntervention.failure_intervention?(pending_ask),
                 {:ok, resolved_pending_ask} <-
                   PendingAsks.resolve(pending_ask, FailureIntervention.carry_on_answer(),
                     answered_via: "callback",
                     config_merge:
                       resolution_config_for_callback(
                         query,
                         bot_config,
                         pending_ask,
                         FailureIntervention.carry_on_answer()
                       )
                   ) do
              {:callback_pending_ask, query_id, resolved_pending_ask,
               FailureIntervention.carry_on_answer(), message_id}
            else
              _ -> {:callback_pending_ask_ignored, query_id}
            end

          {:ok, "askstop", _} when is_binary(query_id) ->
            with chat_id when is_integer(chat_id) <- callback_query_chat_id(query),
                 message_id when is_integer(message_id) <- callback_query_message_id(query),
                 %{} = pending_ask <-
                   PendingAsks.get_unresolved_by_message(bot_config.id, chat_id, message_id),
                 true <- FailureIntervention.failure_intervention?(pending_ask),
                 {:ok, resolved_pending_ask} <-
                   PendingAsks.resolve(pending_ask, FailureIntervention.stop_answer(),
                     answered_via: "callback",
                     config_merge:
                       resolution_config_for_callback(
                         query,
                         bot_config,
                         pending_ask,
                         FailureIntervention.stop_answer()
                       )
                   ) do
              {:callback_pending_ask, query_id, resolved_pending_ask,
               FailureIntervention.stop_answer(), message_id}
            else
              _ -> {:callback_pending_ask_ignored, query_id}
            end

          {:ok, "stopcycle", cycle_id} when is_binary(query_id) and is_binary(cycle_id) ->
            {:callback_stop_cycle, query_id, cycle_id}

          {:ok, "stoploop", _} when is_binary(query_id) ->
            {:callback_stop_active, query_id}

          _ ->
            :ignore
        end
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

  defp callback_query_id(%{"id" => id}), do: normalize_int64(id)
  defp callback_query_id(_query), do: nil

  defp callback_query_chat_id(%{"chat_id" => chat_id}), do: normalize_json_number(chat_id)

  defp callback_query_chat_id(%{"message" => %{"chat_id" => chat_id}}),
    do: normalize_json_number(chat_id)

  defp callback_query_chat_id(_query), do: nil

  defp callback_query_message_id(%{"message_id" => message_id}),
    do: normalize_json_number(message_id)

  defp callback_query_message_id(%{"message" => %{"id" => message_id}}),
    do: normalize_json_number(message_id)

  defp callback_query_message_id(_query), do: nil

  defp normalize_json_number(value) when is_integer(value), do: value

  defp normalize_json_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_json_number(_value), do: nil

  defp normalize_int64(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_int64(""), do: nil
  defp normalize_int64(value) when is_binary(value), do: value
  defp normalize_int64(_value), do: nil

  defp pending_ask_for_message(msg, bot_config, mentioned?, is_reply_to_bot)
       when is_map(msg) and is_map(bot_config) do
    chat_id = msg["chat_id"]

    cond do
      reply_message_id = reply_to_message_id(msg) ->
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

  defp normalize_pending_ask_answer(msg, bot_config) when is_map(msg) and is_map(bot_config) do
    text =
      get_in(msg, ["content", "text", "text"]) ||
        get_in(msg, ["content", "caption", "text"])

    normalize_pending_ask_answer_text(text, bot_config.bot_username)
  end

  defp normalize_pending_ask_answer(_msg, _bot_config), do: nil

  defp normalize_pending_ask_answer_text(text, bot_username)
       when is_binary(text) and is_binary(bot_username) do
    text
    |> String.trim()
    |> String.replace(~r/^@#{Regex.escape(bot_username)}[,:]?\s*/iu, "")
    |> String.trim()
    |> case do
      "" -> nil
      answer -> answer
    end
  end

  defp normalize_pending_ask_answer_text(_text, _bot_username), do: nil

  defp reply_to_message_id(%{
         "reply_to" => %{
           "@type" => "messageReplyToMessage",
           "message_id" => reply_message_id
         }
       })
       when is_integer(reply_message_id),
       do: reply_message_id

  defp reply_to_message_id(_msg), do: nil

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
    debounce_ms = state.bot_config[:debounce_ms] || 0

    if debounce_ms > 0 and is_nil(state.worker_pid) do
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
    reply_to = normalize_reply_to(msg["reply_to_override"] || msg["id"])
    system_prompt = resolve_system_prompt(chat_id, msg, state.bot_config)

    text =
      get_in(msg, ["content", "text", "text"]) ||
        get_in(msg, ["content", "caption", "text"]) || ""

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
    state = normalize_state(state)
    bc = state.bot_config

    if state.worker_pid do
      session_span = Froth.Telegram.Session.span_id(bc.session_id)

      Span.execute([:froth, :telegram, :bot, :busy], session_span, %{
        bot_id: bc.id,
        chat_id: chat_id,
        active_cycle_id: state.cycle && state.cycle.id
      })

      # Buffer the message for mid-loop injection
      mid = Map.get(state, :mid_cycle_messages, [])
      buffered = %{chat_id: chat_id, reply_to: reply_to, text: text, time: DateTime.utc_now()}
      %{state | mid_cycle_messages: mid ++ [buffered]}
    else
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
    {:ok, pid} = Worker.start_link({cycle, config})
    ref = Process.monitor(pid)

    state
    |> reset_cycle_state()
    |> Map.merge(%{
      cycle: cycle,
      worker_pid: pid,
      worker_ref: ref,
      chat_id: chat_id,
      reply_to: reply_to
    })
  end

  defp normalize_reply_to(0), do: nil
  defp normalize_reply_to(reply_to) when is_integer(reply_to), do: reply_to
  defp normalize_reply_to(nil), do: nil
  defp normalize_reply_to(_reply_to), do: nil

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
    state = normalize_state(state)
    notify? = Keyword.get(opts, :notify?, false)

    state =
      if ((notify? and state.cycle) && state.cycle.id == cycle_id) and is_integer(state.chat_id) do
        BotAdapter.send_italic(
          state.bot_config.session_id,
          state.chat_id,
          state.reply_to,
          "stopped"
        )

        state
      else
        state
      end

    state =
      if (state.cycle && state.cycle.id == cycle_id) and is_pid(state.worker_pid) do
        Process.exit(state.worker_pid, {:shutdown, :cancelled})
        reset_cycle_state(state)
      else
        state
      end

    task_ids = Map.get(state.active_tasks, cycle_id, MapSet.new())
    Enum.each(task_ids, &stop_background_task/1)

    prune_cycle_indexes(state, cycle_id)
  end

  # Clear all per-cycle fields back to their struct defaults. Does not touch
  # the cross-cycle indexes (`active_tasks`, `control_prompt_cycles`) — use
  # `prune_cycle_indexes/2` for that.
  defp reset_cycle_state(state) do
    %{
      state
      | cycle: nil,
        worker_pid: nil,
        worker_ref: nil,
        chat_id: nil,
        reply_to: nil,
        awaiting_user_input?: false,
        last_sent_message_id: nil,
        last_sent_message_text: nil,
        current_narration_message_id: nil,
        current_narration_text: nil,
        current_narration_mode: nil,
        mid_cycle_messages: []
    }
  end

  defp prune_cycle_indexes(state, cycle_id) when is_binary(cycle_id) do
    %{
      state
      | active_tasks: Map.delete(state.active_tasks, cycle_id),
        control_prompt_cycles: MapSet.delete(state.control_prompt_cycles, cycle_id)
    }
  end

  defp prune_cycle_indexes(state, _cycle_id), do: state

  defp prepare_tool_call(state, %ToolUse{name: name, input: input} = tool_use, context)
       when is_map(input) do
    chat_id = context[:chat_id] || state.chat_id
    reply_to = context[:reply_to] || state.reply_to
    cycle_id = context[:cycle_id]
    bc = state.bot_config

    if not is_integer(chat_id) do
      {{:error, "missing chat_id in tool context"}, state}
    else
      execution_base = %{
        tool_use_id: tool_use.id,
        bot_id: bc.id,
        bot_username: bc.bot_username,
        session_id: bc.session_id,
        chat_id: chat_id,
        reply_to: reply_to,
        cycle_id: cycle_id,
        provider: state.cycle && state.cycle.provider,
        current_narration_message_id: state.current_narration_message_id,
        current_narration_text: state.current_narration_text,
        current_narration_mode: state.current_narration_mode,
        last_agent_message_id: state.last_sent_message_id,
        system_prompt: resolve_system_prompt(chat_id, nil, bc),
        model: current_cycle_model(state),
        tools: current_cycle_tools(state),
        active_task_ids: current_cycle_task_ids(state, cycle_id),
        thinking: current_cycle_thinking(state),
        effort: current_cycle_effort(state),
        tool_timeout_ms: current_cycle_tool_timeout_ms(state)
      }

      {execution, state} =
        case name do
          "send_message" ->
            {Map.merge(execution_base, %{name: name, input: input}), state}

          "elixir_eval" ->
            {state, send_control_prompt?} = reserve_control_prompt(state, cycle_id)

            {Map.merge(execution_base, %{
               name: name,
               input:
                 input
                 |> Map.put("reply_to", reply_to)
                 |> Map.put("send_control_prompt", send_control_prompt?)
                 |> Map.put("topic", "cycle:#{cycle_id}")
                 |> maybe_put_control_prompt(
                   send_control_prompt?,
                   bc,
                   cycle_id,
                   chat_id,
                   reply_to
                 )
             }), state}

          "run_shell" ->
            {state, send_control_prompt?} = reserve_control_prompt(state, cycle_id)

            {Map.merge(execution_base, %{
               name: name,
               input:
                 input
                 |> Map.put("reply_to", reply_to)
                 |> Map.put("send_control_prompt", send_control_prompt?)
                 |> maybe_put_control_prompt(
                   send_control_prompt?,
                   bc,
                   cycle_id,
                   chat_id,
                   reply_to
                 )
             }), state}

          "spawn_agent" ->
            {Map.merge(execution_base, %{
               name: name,
               input: Map.put(input, "reply_to", reply_to)
             }), state}

          _ ->
            {Map.merge(execution_base, %{name: name, input: input}), state}
        end

      prepared = %{
        execution: execution,
        execute: {ToolExecution, :execute, [execution]}
      }

      {{:ok, prepared}, state}
    end
  end

  defp prepare_tool_call(state, _tool_use, _context),
    do: {{:error, "invalid tool input"}, state}

  defp commit_tool_call(state, _tool_use, context, prepared, outcome) do
    {result, sent_message, narration_message, awaiting_user_input?} =
      normalize_tool_outcome(outcome)

    cycle_id =
      extract_cycle_id(prepared) || extract_cycle_id(context) || extract_cycle_id(outcome)

    state =
      case narration_message do
        %{message_id: _, text: _, mode: _} ->
          track_narration_message(state, narration_message)

        _ ->
          state
      end

    state =
      case {sent_message, awaiting_user_input?} do
        {%{sent: sent, text: text}, true} ->
          track_awaiting_user_input(state, sent, text)

        {%{sent: sent, text: text}, false} ->
          track_sent_message(state, sent, text)

        _ ->
          state
      end

    state = maybe_track_task_from_result(state, cycle_id, result)

    {result, state} = maybe_inject_mid_cycle_messages(result, state)
    {result, state}
  end

  defp reserve_control_prompt(state, cycle_id) when is_binary(cycle_id) do
    {cycles, send_control_prompt?} = ControlPrompt.reserve(state.control_prompt_cycles, cycle_id)
    {%{state | control_prompt_cycles: cycles}, send_control_prompt?}
  end

  defp reserve_control_prompt(state, _cycle_id), do: {state, false}

  defp maybe_put_control_prompt(input, true, bc, cycle_id, chat_id, reply_to)
       when is_binary(cycle_id) and is_integer(chat_id) do
    ControlPrompt.maybe_put(
      input,
      true,
      cycle_id: cycle_id,
      chat_id: chat_id,
      reply_to: reply_to,
      session_id: bc.session_id,
      bot_id: bc.id,
      bot_username: bc.bot_username,
      text: "I am running code and tools before I reply."
    )
  end

  defp maybe_put_control_prompt(input, _send?, _bc, _cycle_id, _chat_id, _reply_to), do: input

  defp normalize_tool_outcome(%{result: result} = outcome) do
    {result, outcome[:sent_message], outcome[:narration_message],
     outcome[:awaiting_user_input] == true}
  end

  defp normalize_tool_outcome(result), do: {result, nil, nil, false}

  defp extract_cycle_id(%{execution: %{cycle_id: cycle_id}}) when is_binary(cycle_id),
    do: cycle_id

  defp extract_cycle_id(%{cycle_id: cycle_id}) when is_binary(cycle_id), do: cycle_id
  defp extract_cycle_id(_), do: nil

  defp maybe_inject_mid_cycle_messages(result, %{mid_cycle_messages: [_ | _] = msgs} = state) do
    injection =
      msgs
      |> Enum.map(fn %{text: text} ->
        "[Message received during tool execution: " <> text <> "]"
      end)
      |> Enum.join("\n")

    new_result =
      case result do
        {:ok, text} when is_binary(text) ->
          {:ok, text <> "\n\n" <> injection}

        {:ok, blocks} when is_list(blocks) ->
          {:ok, blocks ++ [%{"type" => "text", "text" => injection}]}

        other ->
          other
      end

    {new_result, %{state | mid_cycle_messages: []}}
  end

  defp maybe_inject_mid_cycle_messages(result, state), do: {result, state}

  defp maybe_resume_pending_ask(%{pending_ask_resumes: []} = state), do: state

  defp maybe_resume_pending_ask(%{pending_ask_resumes: [resume | rest]} = state) do
    state
    |> Map.put(:pending_ask_resumes, rest)
    |> resume_pending_ask(resume)
  end

  defp maybe_resume_buffered_cycle(state, []), do: state

  defp maybe_resume_buffered_cycle(state, [%{chat_id: chat_id} | _] = messages)
       when is_integer(chat_id) do
    text =
      messages
      |> Enum.map(&String.trim(&1.text || ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    reply_to =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{reply_to: value} when is_integer(value) -> value
        _ -> nil
      end)

    if text == "" do
      state
    else
      message = SyntheticMessage.build(chat_id, text, reply_to: reply_to)
      start_cycle_from_message(state, message)
    end
  end

  defp maybe_resume_buffered_cycle(state, _messages), do: state

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
    resume = %{pending_ask: pending_ask, answer: answer, reply_to: normalize_reply_to(reply_to)}

    cond do
      live_pending_ask_cycle?(state, pending_ask) ->
        resolve_pending_ask_live(state, resume)

      is_pid(state.worker_pid) ->
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
            normalize_reply_to(reply_to || pending_ask.message_id)
          )
        else
          _ ->
            state
        end
    end
  end

  defp resolve_pending_ask_live(state, %{pending_ask: pending_ask} = _resume)
       when is_map(pending_ask) do
    case pending_ask_resolution(pending_ask) do
      {:stop_cycle, mode} ->
        state = stop_pending_ask_tasks(state, pending_ask, mode)
        state = clear_pending_ask_wait(state)

        try do
          _ =
            Worker.resolve_pending_ask(
              state.worker_pid,
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
          case Worker.resolve_pending_ask(
                 state.worker_pid,
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
              reply_to: normalize_reply_to(pending_ask.answer_message_id)
            })
        end
    end
  end

  defp live_pending_ask_cycle?(
         %{cycle: %Cycle{id: cycle_id}, worker_pid: worker_pid},
         pending_ask
       )
       when is_binary(cycle_id) and is_pid(worker_pid) do
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

    %{
      state
      | active_tasks: Map.delete(state.active_tasks, cycle_id),
        control_prompt_cycles: MapSet.delete(state.control_prompt_cycles, cycle_id)
    }
  end

  defp stop_pending_ask_cycle(state, _pending_ask, _mode), do: state

  defp stop_pending_ask_tasks(state, pending_ask, mode) do
    task_ids = Map.get(state.active_tasks, pending_ask.cycle_id, MapSet.new()) |> Enum.to_list()

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

  defp clear_pending_ask_wait(state) do
    %{state | awaiting_user_input?: false}
  end

  defp resolution_config_for_message(msg, bot_config, pending_ask, answer)
       when is_map(msg) and is_map(bot_config) do
    actor_id = get_in(msg, ["sender_id", "user_id"])

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
    actor_id = callback_query_sender_id(query)

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

  defp callback_query_sender_id(%{"sender_user_id" => sender_user_id})
       when is_integer(sender_user_id),
       do: sender_user_id

  defp callback_query_sender_id(%{"sender_id" => %{"user_id" => sender_user_id}})
       when is_integer(sender_user_id),
       do: sender_user_id

  defp callback_query_sender_id(_query), do: nil

  defp maybe_track_task_from_result(state, cycle_id, {:ok, result}) when is_binary(cycle_id) do
    case extract_task_id(result) do
      task_id when is_binary(task_id) ->
        send(self(), {:register_cycle_task, cycle_id, task_id})
        state

      _ ->
        state
    end
  end

  defp maybe_track_task_from_result(state, _cycle_id, _result), do: state

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

  defp resolve_system_prompt(chat_id, msg, bot_config)
       when is_integer(chat_id) and (is_map(msg) or is_nil(msg)) and is_map(bot_config) do
    case bot_config.system_prompt_fun do
      prompt_fun when is_function(prompt_fun, 3) ->
        prompt_fun.(chat_id, bot_config, msg)

      prompt_fun when is_function(prompt_fun, 2) ->
        prompt_fun.(chat_id, bot_config)

      prompt_fun when is_function(prompt_fun, 1) ->
        prompt_fun.(chat_id)

      prompt when is_binary(prompt) and prompt != "" ->
        prompt

      _ ->
        bot_config.system_prompt || ""
    end
  end

  defp send_agent_response(
         %{chat_id: chat_id, reply_to: reply_to, bot_config: bc} = state,
         content
       )
       when is_integer(chat_id) do
    case normalize_agent_reply_text(extract_text(content)) do
      {:ok, text, entities} ->
        send_plaintext_response(state, bc.session_id, chat_id, reply_to, text, entities: entities)

      :no_reply ->
        state

      :empty ->
        state
    end
  end

  defp send_agent_response(state, _), do: state

  defp send_plaintext_response(state, session_id, chat_id, reply_to, text, opts)
       when is_binary(session_id) and is_integer(chat_id) and is_binary(text) do
    send_opts = [reply_to: reply_to] ++ Keyword.take(opts, [:entities])

    chunks = split_long_text(text, @telegram_text_limit)

    Enum.reduce(chunks, state, fn chunk, acc ->
      # Only first chunk gets entities (formatting offsets won't be valid for later chunks)
      chunk_opts = if chunk == hd(chunks), do: send_opts, else: [reply_to: reply_to]

      case BotAdapter.send_message(session_id, chat_id, chunk, chunk_opts) do
        {:ok, sent} ->
          track_sent_message(acc, sent, chunk)

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp split_long_text(text, limit) when is_binary(text) and is_integer(limit) do
    if String.length(text) <= limit do
      [text]
    else
      do_split_text(text, limit, [])
    end
  end

  defp do_split_text("", _limit, acc), do: Enum.reverse(acc)

  defp do_split_text(text, limit, acc) do
    if String.length(text) <= limit do
      Enum.reverse([text | acc])
    else
      # Try to split at a double newline (paragraph boundary) within the limit
      candidate = String.slice(text, 0, limit)

      split_pos =
        case :binary.matches(candidate, "\n\n") |> List.last() do
          {pos, _len} when pos > div(limit, 4) ->
            pos + 2

          _ ->
            # Fall back to last single newline
            case :binary.matches(candidate, "\n") |> List.last() do
              {pos, _len} when pos > div(limit, 4) -> pos + 1
              _ -> limit
            end
        end

      {chunk, rest} = String.split_at(text, split_pos)
      do_split_text(String.trim_leading(rest), limit, [String.trim_trailing(chunk) | acc])
    end
  end

  defp normalize_agent_reply_text(text) when is_binary(text) do
    {cleaned, entities} = process_grok_citations(text)

    cleaned
    |> String.trim()
    |> case do
      "" ->
        :empty

      trimmed ->
        if String.upcase(trimmed) == "NO_REPLY" do
          :no_reply
        else
          {:ok, trimmed, entities}
        end
    end
  end

  @citation_re ~r/\[\[(\d+)\]\]\(([^)]+)\)/

  defp process_grok_citations(text) when is_binary(text) do
    # Strip XML-style grok tags first
    text =
      text
      |> then(&Regex.replace(~r/<grok:render\b[^>]*\/>/u, &1, ""))
      |> then(&Regex.replace(~r/<grok:render\b[^>]*>.*?<\/grok:render>/su, &1, ""))
      |> then(&Regex.replace(~r/<grok:cite\b[^>]*>.*?<\/grok:cite>/su, &1, ""))
      |> then(&Regex.replace(~r/<argument\b[^>]*>.*?<\/argument>/su, &1, ""))

    # Collect [[N]](url) citations, strip inline, append as footnotes
    citations =
      Regex.scan(@citation_re, text)
      |> Enum.map(fn [_full, num, url] -> {num, url} end)
      |> Enum.uniq_by(fn {num, _url} -> num end)

    cleaned = Regex.replace(@citation_re, text, "")

    footnotes =
      case citations do
        [] ->
          ""

        refs ->
          "\n\n" <>
            Enum.map_join(refs, "\n", fn {num, url} ->
              clean_url = Regex.replace(~r/\[(?:post|web):\d+\]$/, url, "")
              "[#{num}] #{clean_url}"
            end)
      end

    {cleaned <> footnotes, []}
  end

  defp process_grok_citations(_), do: {"", []}

  defp send_message_tool_enabled?(bot_config) when is_map(bot_config) do
    bot_config
    |> resolve_tool_specs()
    |> Enum.any?(&match?(%{"name" => "send_message"}, &1))
  end

  defp send_message_tool_enabled?(_), do: false

  defp resolve_tool_specs(bot_config) when is_map(bot_config) do
    bot_config
    |> case do
      %{tools: tools} when is_list(tools) ->
        tools

      _ ->
        case Map.get(bot_config, :tools_module) do
          module when is_atom(module) ->
            if Code.ensure_loaded?(module) and function_exported?(module, :specs_for_api, 0) do
              module.specs_for_api()
            else
              []
            end

          _ ->
            []
        end
    end
  end

  defp resolve_tool_specs(_), do: []

  defp track_sent_message(state, sent, text) when is_map(state) and is_binary(text) do
    base =
      state
      |> clear_current_narration()
      |> Map.put(:awaiting_user_input?, false)
      |> Map.put(:last_sent_message_text, text)

    case sent_message_id(sent) do
      id when is_integer(id) ->
        %{base | last_sent_message_id: id}

      _ ->
        base
    end
  end

  defp track_awaiting_user_input(state, _sent, _text) do
    state
    |> clear_current_narration()
    |> Map.put(:awaiting_user_input?, true)
    |> Map.put(:last_sent_message_id, nil)
    |> Map.put(:last_sent_message_text, nil)
  end

  defp track_narration_message(
         state,
         %{message_id: message_id, text: text, mode: mode}
       )
       when is_integer(message_id) and is_binary(text) and mode in [:italic, :markdown] do
    %{
      state
      | current_narration_message_id: message_id,
        current_narration_text: text,
        current_narration_mode: mode
    }
  end

  defp track_narration_message(state, _), do: state

  defp clear_current_narration(state) do
    %{
      state
      | current_narration_message_id: nil,
        current_narration_text: nil,
        current_narration_mode: nil
    }
  end

  defp pending_ask_worker_config(state, pending_ask, reply_to)
       when is_map(pending_ask) do
    config = pending_ask.config || %{}
    system_prompt = config_string(config, "system") || state.bot_config.system_prompt || ""

    tools =
      config_list(config, "tools") || resolve_tool_specs(state.bot_config) || []

    %Config{
      system: system_prompt,
      model: config_string(config, "model") || state.bot_config.model,
      tools: tools,
      tool_executor: self(),
      context: %{
        chat_id: pending_ask.chat_id,
        reply_to: normalize_reply_to(reply_to || pending_ask.message_id),
        bot_id: state.bot_config.id,
        session_id: state.bot_config.session_id,
        bot_username: state.bot_config.bot_username
      },
      thinking: config_map(config, "thinking") || state.bot_config.thinking,
      effort: config_string(config, "effort") || state.bot_config.effort,
      tool_timeout_ms: config_integer(config, "tool_timeout_ms")
    }
  end

  defp current_cycle_model(%{cycle: %Cycle{model: model}}) when is_binary(model) and model != "",
    do: model

  defp current_cycle_model(%{bot_config: %{model: model}}) when is_binary(model), do: model
  defp current_cycle_model(_state), do: nil

  defp current_cycle_tools(%{cycle: %Cycle{config: %{"tool_specs" => tool_specs}}})
       when is_list(tool_specs),
       do: tool_specs

  defp current_cycle_tools(%{bot_config: bot_config}), do: resolve_tool_specs(bot_config)

  defp current_cycle_task_ids(%{active_tasks: active_tasks}, cycle_id)
       when is_map(active_tasks) and is_binary(cycle_id) do
    active_tasks
    |> Map.get(cycle_id, MapSet.new())
    |> Enum.sort()
  end

  defp current_cycle_task_ids(_state, _cycle_id), do: []

  defp current_cycle_thinking(%{cycle: %Cycle{config: %{"thinking" => thinking}}})
       when is_map(thinking),
       do: thinking

  defp current_cycle_thinking(%{bot_config: %{thinking: thinking}}) when is_map(thinking),
    do: thinking

  defp current_cycle_thinking(_state), do: nil

  defp current_cycle_effort(%{cycle: %Cycle{config: %{"effort" => effort}}})
       when is_binary(effort) and effort != "",
       do: effort

  defp current_cycle_effort(%{bot_config: %{effort: effort}}) when is_binary(effort),
    do: effort

  defp current_cycle_effort(_state), do: nil

  defp current_cycle_tool_timeout_ms(%{cycle: %Cycle{config: %{"tool_timeout_ms" => timeout_ms}}})
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: timeout_ms

  defp current_cycle_tool_timeout_ms(_state), do: nil

  defp config_string(config, key) when is_map(config) and is_binary(key) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp config_string(_config, _key), do: nil

  defp config_integer(config, key) when is_map(config) and is_binary(key) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp config_integer(_config, _key), do: nil

  defp config_map(config, key) when is_map(config) and is_binary(key) do
    case Map.get(config, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp config_map(_config, _key), do: nil

  defp config_list(config, key) when is_map(config) and is_binary(key) do
    case Map.get(config, key) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  defp config_list(_config, _key), do: nil

  defp sync_sent_message_id(state, old_id, new_id)
       when is_integer(old_id) and is_integer(new_id) do
    state =
      if state.last_sent_message_id == old_id do
        %{state | last_sent_message_id: new_id}
      else
        state
      end

    if state.current_narration_message_id == old_id do
      %{state | current_narration_message_id: new_id}
    else
      state
    end
  end

  defp sync_sent_message_id(state, _old_id, _new_id), do: state

  defp sent_message_id(%{"id" => id}) when is_integer(id), do: id

  defp sent_message_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp sent_message_id(_), do: nil

  defp maybe_append_cycle_footer(
         %{
           last_sent_message_id: msg_id,
           awaiting_user_input?: false,
           chat_id: chat_id,
           bot_config: bc
         } = state
       )
       when is_integer(msg_id) and is_integer(chat_id) do
    case build_cycle_cost_footer(state) do
      nil ->
        state

      footer ->
        maybe_apply_cycle_footer(state, bc.session_id, chat_id, footer)
    end
  end

  defp maybe_append_cycle_footer(state), do: state

  defp maybe_apply_cycle_footer(
         %{last_sent_message_id: msg_id, last_sent_message_text: text} = state,
         session_id,
         chat_id,
         footer
       )
       when is_integer(msg_id) and is_binary(text) and is_binary(footer) do
    full_text = append_footer(text, footer)

    if String.length(full_text) <= @telegram_text_limit do
      case BotAdapter.edit_message_text(session_id, chat_id, msg_id, full_text) do
        {:ok, _} ->
          state

        {:error, _reason} ->
          _ = BotAdapter.send_message(session_id, chat_id, footer, reply_to: state.reply_to)
          state
      end
    else
      _ = BotAdapter.send_message(session_id, chat_id, footer, reply_to: state.reply_to)
      state
    end
  end

  defp maybe_apply_cycle_footer(state, session_id, chat_id, footer) do
    _ = BotAdapter.send_message(session_id, chat_id, footer, reply_to: state.reply_to)
    state
  end

  defp append_footer(text, footer) when is_binary(text) and is_binary(footer) do
    trimmed = String.trim_trailing(text)
    if String.ends_with?(trimmed, footer), do: trimmed, else: trimmed <> "\n\n" <> footer
  end

  defp build_cycle_cost_footer(%{cycle: %Cycle{id: cycle_id}}) when is_binary(cycle_id) do
    case Repo.get(Cycle, cycle_id) do
      %Cycle{usage: usage} = reloaded when is_map(usage) ->
        render_cycle_cost_footer(reloaded, usage, reloaded.cost_usd || 0.0)

      _ ->
        nil
    end
  end

  defp build_cycle_cost_footer(_state), do: nil

  defp render_cycle_cost_footer(%Cycle{} = cycle, usage, cost_usd) do
    total_in = total_input_tokens(usage)
    total_out = usage_int(usage["output_tokens"])

    if total_in <= 0 and total_out <= 0 do
      nil
    else
      duration = format_seconds(cycle_elapsed_seconds(cycle))
      in_part = format_tokens_k(total_in)
      out_part = format_tokens_k(total_out)
      cache_write_part = format_tokens_k(usage_int(usage["cache_creation_input_tokens"]))
      cache_read_part = format_tokens_k(usage_int(usage["cache_read_input_tokens"]))
      cost = "$" <> :erlang.float_to_binary(cost_usd * 1.0, decimals: 3)

      "[#{duration} | #{in_part} in | #{out_part} out | #{cache_write_part} cw | #{cache_read_part} cr | #{cost}]"
    end
  end

  defp cycle_elapsed_seconds(%Cycle{started_at: %DateTime{} = started_at} = cycle) do
    finished_at = cycle.finished_at || DateTime.utc_now()
    DateTime.diff(finished_at, started_at, :millisecond) |> max(0) |> Kernel./(1000)
  end

  defp cycle_elapsed_seconds(_cycle), do: 0.0

  defp format_seconds(seconds) when is_number(seconds) do
    value = if seconds < 0, do: 0.0, else: seconds * 1.0
    :erlang.float_to_binary(value, decimals: 1) <> "s"
  end

  defp format_tokens_k(tokens) when is_integer(tokens) and tokens >= 0 do
    cond do
      tokens == 0 ->
        "0k"

      rem(tokens, 1000) == 0 ->
        "#{div(tokens, 1000)}k"

      true ->
        k = tokens / 1000
        format_decimal(k, 1) <> "k"
    end
  end

  defp format_tokens_k(_tokens), do: "0k"

  defp format_decimal(number, decimals) when is_number(number) and is_integer(decimals) do
    number
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp total_input_tokens(usage) when is_map(usage) do
    usage_int(usage["input_tokens"]) +
      usage_int(usage["cache_creation_input_tokens"]) +
      usage_int(usage["cache_read_input_tokens"])
  end

  defp total_input_tokens(_usage), do: 0

  defp usage_int(value) when is_integer(value) and value >= 0, do: value

  defp usage_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp usage_int(_value), do: 0

  defp extract_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(_), do: ""

  # Handles hot code reload where in-memory struct instances may predate new fields.
  defp normalize_state(%__MODULE__{} = state) do
    state_keys = state_keys()

    state
    |> Map.from_struct()
    |> Map.take(state_keys)
    |> then(&struct(__MODULE__, &1))
  end

  defp normalize_state(state) when is_map(state) do
    state_keys = state_keys()

    state
    |> Map.take(state_keys)
    |> then(&struct(__MODULE__, &1))
  end

  defp state_keys do
    __MODULE__.__struct__()
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
  end
end
