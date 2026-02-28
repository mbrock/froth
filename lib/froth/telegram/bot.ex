defmodule Froth.Telegram.Bot do
  @moduledoc """
  Telegram bot runtime backed by `Froth.Agent` cycles.

  Supports mention/reply activation, automatic tool execution, and cycle stop
  controls for Telegram mini-app inspection.
  """

  use GenServer

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, Message, ToolUse, Worker}
  alias Froth.Telemetry.Span
  alias Froth.Inference.Prompt
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Telegram.BotAdapter
  alias Froth.Telegram.CycleLink

  defstruct [
    :bot_config,
    :cycle,
    :worker_pid,
    :worker_ref,
    :chat_id,
    :reply_to,
    :cycle_started_ms,
    :last_tool_error,
    :last_sent_message_id,
    :last_sent_message_text,
    cycle_usage_total: %{},
    cycle_cost_usd: 0.0,
    stream_usage_current: %{},
    active_tasks: %{},
    control_prompt_cycles: MapSet.new(),
    cycle_replied?: false
  ]

  @recap_sessions_limit 10
  @recap_max_tokens_approx 20_000
  @telegram_text_limit 4096

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
      tools: Keyword.get(opts, :tools, []),
      thinking: Keyword.get(opts, :thinking),
      effort: Keyword.get(opts, :effort)
    }

    :ok = BotAdapter.subscribe(bot_config.session_id)

    Span.execute([:froth, :telegram, :bot, :listening], nil, %{
      bot_id: bot_config.id,
      session_id: bot_config.session_id,
      username: bot_config.bot_username
    })

    {:ok, %__MODULE__{bot_config: bot_config}}
  end

  @impl true
  def handle_info({:telegram_update, update}, state) do
    case route_update(update, state.bot_config) do
      {:mention, msg} ->
        {:noreply, start_cycle_from_message(state, msg)}

      {:callback_stop_cycle, query_id, cycle_id} ->
        BotAdapter.answer_callback(state.bot_config.session_id, query_id)
        {:noreply, stop_cycle(state, cycle_id, notify?: true)}

      {:callback_stop_active, query_id} ->
        BotAdapter.answer_callback(state.bot_config.session_id, query_id)

        state =
          case state.cycle do
            %Cycle{id: cycle_id} -> stop_cycle(state, cycle_id, notify?: true)
            _ -> state
          end

        {:noreply, state}

      :ignore ->
        {:noreply, state}
    end
  end

  def handle_info({:event, _event, %Message{role: :agent, content: content}}, state) do
    state = normalize_state(state)
    state = commit_stream_usage(state)
    {:noreply, send_agent_response(state, content)}
  end

  def handle_info({:event, _event, %Message{role: :user, content: content}}, state) do
    state = normalize_state(state)
    {:noreply, maybe_capture_tool_error(state, content)}
  end

  def handle_info({:event, _event, %Message{}}, state) do
    {:noreply, state}
  end

  def handle_info({:stream, {:usage, usage_event}}, state) when is_map(usage_event) do
    state = normalize_state(state)

    usage =
      cond do
        is_map(usage_event["accumulated_usage"]) ->
          usage_event["accumulated_usage"]

        is_map(usage_event["usage"]) ->
          merge_usage_maps(state.stream_usage_current, usage_event["usage"])

        true ->
          state.stream_usage_current
      end

    {:noreply, %{state | stream_usage_current: usage}}
  end

  def handle_info({:stream, _event}, state), do: {:noreply, state}

  def handle_info({:eval_done_detail, %{status: status, result: result}}, state)
      when status in [:error, "error"] and is_binary(result) do
    {:noreply, put_last_tool_error(state, result)}
  end

  def handle_info({:eval_done_detail, %{status: status, io_output: io_output}}, state)
      when status in [:error, "error"] and is_binary(io_output) do
    {:noreply, put_last_tool_error(state, io_output)}
  end

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
        {:DOWN, ref, :process, pid, reason},
        %{worker_ref: ref, worker_pid: pid} = state
      ) do
    state = normalize_state(state)

    Span.execute([:froth, :telegram, :bot, :cycle_finished], nil, %{
      cycle_id: state.cycle && state.cycle.id,
      bot_id: state.bot_config.id,
      reason: reason
    })

    state =
      state
      |> commit_stream_usage()
      |> maybe_append_cycle_footer()
      |> maybe_send_silent_cycle_fallback()

    {:noreply,
     %{
       state
       | cycle: nil,
         worker_pid: nil,
         worker_ref: nil,
         chat_id: nil,
         reply_to: nil,
         cycle_started_ms: nil,
         cycle_replied?: false,
         last_tool_error: nil,
         last_sent_message_id: nil,
         last_sent_message_text: nil,
         cycle_usage_total: %{},
         cycle_cost_usd: 0.0,
         stream_usage_current: %{}
     }}
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

  def handle_cast({:auto_approve, _ref}, state), do: {:noreply, state}
  def handle_cast({:continue_loop, _id}, state), do: {:noreply, state}
  def handle_cast({:abort_tool, _ref}, state), do: {:noreply, state}
  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_call({:execute, %ToolUse{} = tool_use, context}, _from, state) do
    {result, state} = execute_tool_call(state, tool_use, context)
    {:reply, result, state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, "unsupported"}, state}

  defp route_update(%{"@type" => "updateNewMessage", "message" => msg}, bot_config)
       when is_map(msg) do
    sender = get_in(msg, ["sender_id", "user_id"])
    chat_id = msg["chat_id"]

    is_reply_to_bot = replied_to_bot?(msg, bot_config.bot_user_id)

    cond do
      sender == bot_config.bot_user_id ->
        :ignore

      (BotAdapter.mentioned?(
         msg,
         bot_config.bot_username,
         bot_config.bot_user_id,
         bot_config.name_triggers
       ) or is_reply_to_bot) and
          BotAdapter.allowed_chat?(chat_id, bot_config.owner_user_id, bot_config.session_id) ->
        {:mention, msg}

      true ->
        :ignore
    end
  end

  defp route_update(%{"@type" => "updateNewCallbackQuery"} = query, _bot_config) do
    route_callback_query(query)
  end

  defp route_update(_, _), do: :ignore

  defp route_callback_query(query) do
    query_id = query["id"]

    case parse_callback_payload(query) do
      {:ok, "stopcycle", cycle_id} when is_integer(query_id) and is_binary(cycle_id) ->
        {:callback_stop_cycle, query_id, cycle_id}

      {:ok, "stoploop", _} when is_integer(query_id) ->
        {:callback_stop_active, query_id}

      _ ->
        :ignore
    end
  end

  defp parse_callback_payload(%{
         "payload" => %{"@type" => "callbackQueryPayloadData", "data" => data_b64}
       }) do
    with {:ok, data} <- Base.decode64(data_b64),
         [action, arg] when action in ["stopcycle", "stoploop"] <-
           String.split(data, ":", parts: 2) do
      {:ok, action, arg}
    else
      _ -> :error
    end
  end

  defp parse_callback_payload(_), do: :error

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

  defp start_cycle_from_message(state, msg) when is_map(msg) do
    chat_id = msg["chat_id"]
    reply_to = msg["id"]

    text =
      get_in(msg, ["content", "text", "text"]) ||
        get_in(msg, ["content", "caption", "text"]) || ""

    user_content = build_initial_user_content(msg, state.bot_config)

    start_cycle(state, chat_id, reply_to, text, user_content)
  end

  defp start_cycle(state, chat_id, reply_to, text, user_content)
       when is_integer(chat_id) and is_integer(reply_to) and is_binary(text) do
    state = normalize_state(state)
    bc = state.bot_config

    if state.worker_pid do
      Span.execute([:froth, :telegram, :bot, :busy], nil, %{bot_id: bc.id, chat_id: chat_id})
      BotAdapter.send_message(bc.session_id, chat_id, "(busy, try again in a moment)")
      state
    else
      BotAdapter.send_typing(bc.session_id, chat_id)

      initial_content =
        if is_nil(user_content) do
          text
        else
          user_content
        end

      message = Repo.insert!(%Message{role: :user, content: Message.wrap(initial_content)})
      cycle = Repo.insert!(%Cycle{})
      Repo.insert!(%Agent.Event{cycle_id: cycle.id, head_id: message.id, seq: 0})

      Repo.insert!(%CycleLink{
        cycle_id: cycle.id,
        bot_id: bc.id,
        chat_id: chat_id,
        reply_to: reply_to
      })

      config = %Config{
        system: resolve_system_prompt(chat_id, bc),
        model: bc.model,
        tools: bc.tools || [],
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

      Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle.id}")
      {:ok, pid} = Worker.start_link({cycle, config})
      ref = Process.monitor(pid)

      Span.execute([:froth, :telegram, :bot, :cycle_started], nil, %{
        bot_id: bc.id,
        cycle_id: cycle.id,
        chat_id: chat_id
      })

      %{
        state
        | cycle: cycle,
          worker_pid: pid,
          worker_ref: ref,
          chat_id: chat_id,
          reply_to: reply_to,
          cycle_started_ms: System.monotonic_time(:millisecond),
          cycle_replied?: false,
          last_tool_error: nil,
          last_sent_message_id: nil,
          last_sent_message_text: nil,
          cycle_usage_total: %{},
          cycle_cost_usd: 0.0,
          stream_usage_current: %{}
      }
    end
  end

  defp start_cycle(state, _chat_id, _reply_to, _text, _user_content), do: state

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
        Process.exit(state.worker_pid, :kill)

        %{
          state
          | cycle: nil,
            worker_pid: nil,
            worker_ref: nil,
            chat_id: nil,
            reply_to: nil,
            cycle_started_ms: nil,
            cycle_replied?: false,
            last_tool_error: nil,
            last_sent_message_id: nil,
            last_sent_message_text: nil,
            cycle_usage_total: %{},
            cycle_cost_usd: 0.0,
            stream_usage_current: %{}
        }
      else
        state
      end

    task_ids = Map.get(state.active_tasks, cycle_id, MapSet.new())

    Enum.each(task_ids, fn task_id ->
      stop_background_task(task_id)
    end)

    %{
      state
      | active_tasks: Map.delete(state.active_tasks, cycle_id),
        control_prompt_cycles: MapSet.delete(state.control_prompt_cycles, cycle_id)
    }
  end

  defp execute_tool_call(state, %ToolUse{name: name, input: input}, context)
       when is_map(input) do
    chat_id = context[:chat_id] || state.chat_id
    reply_to = context[:reply_to] || state.reply_to
    cycle_id = context[:cycle_id]
    bc = state.bot_config

    if not is_integer(chat_id) do
      {{:error, "missing chat_id in tool context"}, state}
    else
      {result, state} =
        case name do
          "send_message" ->
            text = input["text"] || ""

            {result, state} =
              case BotAdapter.send_message(bc.session_id, chat_id, text, reply_to: reply_to) do
                {:ok, sent} ->
                  {{:ok, "sent"}, track_sent_message(state, sent, text)}

                {:error, reason} ->
                  error = inspect(reason)
                  {{:error, error}, put_last_tool_error(state, error)}
              end

            {result, state}

          "elixir_eval" ->
            state = maybe_send_control_prompt(state, cycle_id, chat_id, reply_to)

            result =
              Tools.execute(
                name,
                input,
                chat_id,
                bot_id: bc.id,
                session_id: bc.session_id,
                topic: "cycle:#{cycle_id}"
              )

            {result, state}

          "run_shell" ->
            state = maybe_send_control_prompt(state, cycle_id, chat_id, reply_to)

            result =
              Tools.execute(
                name,
                input,
                chat_id,
                bot_id: bc.id,
                session_id: bc.session_id
              )

            {result, state}

          _ ->
            {Tools.execute(name, input, chat_id, bot_id: bc.id, session_id: bc.session_id), state}
        end

      state =
        state
        |> maybe_track_task_from_result(cycle_id, result)
        |> maybe_track_tool_error(result)

      {result, state}
    end
  end

  defp execute_tool_call(state, _tool_use, _context), do: {{:error, "invalid tool input"}, state}

  defp maybe_send_control_prompt(state, cycle_id, chat_id, reply_to)
       when is_binary(cycle_id) and is_integer(chat_id) do
    if MapSet.member?(state.control_prompt_cycles, cycle_id) do
      state
    else
      bc = state.bot_config
      token = "cycle_#{bc.id}_#{cycle_id}"
      stop_data = Base.encode64("stopcycle:#{cycle_id}")

      buttons = [
        %{
          "@type" => "inlineKeyboardButton",
          "text" => "Open",
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeUrl",
            "url" => "https://t.me/#{bc.bot_username}/tool?startapp=#{token}"
          }
        },
        %{
          "@type" => "inlineKeyboardButton",
          "text" => "Stop",
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeCallback",
            "data" => stop_data
          }
        }
      ]

      _ =
        BotAdapter.send_message(
          bc.session_id,
          chat_id,
          "I am running code and tools before I reply.",
          reply_to: reply_to,
          reply_markup: %{
            "@type" => "replyMarkupInlineKeyboard",
            "rows" => [buttons]
          }
        )

      %{state | control_prompt_cycles: MapSet.put(state.control_prompt_cycles, cycle_id)}
    end
  end

  defp maybe_send_control_prompt(state, _cycle_id, _chat_id, _reply_to), do: state

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

  defp resolve_system_prompt(chat_id, bot_config)
       when is_integer(chat_id) and is_map(bot_config) do
    case bot_config.system_prompt_fun do
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

  defp build_initial_user_content(%{"chat_id" => chat_id} = msg, bot_config)
       when is_integer(chat_id) and is_map(bot_config) do
    context_opts =
      case message_unix(msg) do
        unix when is_integer(unix) ->
          [before_unix: unix, telegram_session_id: bot_config.session_id]

        _ ->
          [telegram_session_id: bot_config.session_id]
      end

    context_blocks = Froth.Summarizer.context_blocks(chat_id, context_opts)

    task_overview = Froth.Tasks.context_summary(bot_config.id, chat_id)
    new_messages_section = format_new_messages([msg])

    new_messages_section =
      if task_overview != "" do
        task_overview <> "\n\n" <> new_messages_section
      else
        new_messages_section
      end

    session_recap = previous_session_recap(bot_config.id, chat_id)

    new_messages_section =
      if session_recap != "" do
        session_recap <> "\n\n" <> new_messages_section
      else
        new_messages_section
      end

    Prompt.initial_user_content(context_blocks, "", new_messages_section)
  end

  defp build_initial_user_content(_msg, _bot_config), do: nil

  defp message_unix(%{"date" => value}) when is_integer(value), do: value

  defp message_unix(%{"date" => value}) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp message_unix(_), do: nil

  defp format_new_messages(messages) when is_list(messages) do
    messages
    |> sort_messages()
    |> Enum.map_join("\n\n", fn msg ->
      sender = get_in(msg, ["sender_id", "user_id"]) || "unknown"
      message_id = msg["id"] || "unknown"

      text =
        get_in(msg, ["content", "text", "text"]) ||
          get_in(msg, ["content", "caption", "text"]) || ""

      """
      <message id=\"#{message_id}\" from=\"#{sender}\">
      #{text}
      </message>
      """
      |> String.trim()
    end)
  end

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, &to_int_or_fallback(&1["id"]))
  end

  defp to_int_or_fallback(value) when is_integer(value), do: value

  defp to_int_or_fallback(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_int_or_fallback(_), do: 0

  defp previous_session_recap(bot_id, chat_id) when is_binary(bot_id) and is_integer(chat_id) do
    links =
      Repo.all(
        from(l in CycleLink,
          join: c in Cycle,
          on: c.id == l.cycle_id,
          where: l.bot_id == ^bot_id and l.chat_id == ^chat_id,
          order_by: [desc: c.inserted_at],
          limit: 20,
          select: %{cycle_id: l.cycle_id, inserted_at: c.inserted_at}
        ),
        log: false
      )

    interesting =
      links
      |> Enum.map(fn link ->
        api_messages = load_cycle_api_messages(link.cycle_id)
        %{cycle_id: link.cycle_id, inserted_at: link.inserted_at, api_messages: api_messages}
      end)
      |> Enum.filter(&has_real_tools?(&1.api_messages))
      |> Enum.take(@recap_sessions_limit)

    if interesting == [] do
      ""
    else
      sections = Enum.map(interesting, &format_session_recap/1)
      total = Enum.join(sections, "\n\n")

      if String.length(total) > @recap_max_tokens_approx * 4 do
        truncate_recap(interesting, @recap_max_tokens_approx * 4)
      else
        total
      end
    end
  end

  defp load_cycle_api_messages(cycle_id) do
    head_id = Agent.latest_head_id(%Cycle{id: cycle_id})

    head_id
    |> Agent.load_messages()
    |> Enum.map(&Message.to_api/1)
  end

  defp has_real_tools?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %{"role" => "assistant", "content" => content} when is_list(content) ->
        Enum.any?(content, fn block ->
          block["type"] == "tool_use" and block["name"] not in ["send_message"]
        end)

      _ ->
        false
    end)
  end

  defp has_real_tools?(_), do: false

  defp truncate_recap(sessions, max_chars) do
    {sections, _remaining} =
      Enum.reduce(sessions, {[], max_chars}, fn session, {acc, budget} ->
        section = format_session_recap(session)
        len = String.length(section)

        if budget - len > 0 do
          {[section | acc], budget - len}
        else
          {acc, 0}
        end
      end)

    sections
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  defp format_session_recap(session) do
    entries =
      (session.api_messages || [])
      |> Enum.flat_map(fn
        %{"role" => "assistant", "content" => content} when is_list(content) ->
          Enum.flat_map(content, fn
            %{"type" => "tool_use", "name" => "send_message"} ->
              []

            %{"type" => "tool_use", "name" => name, "input" => input} ->
              [{:call, name, recap_tool_snippet(name, input)}]

            _ ->
              []
          end)

        %{"role" => "user", "content" => content} when is_list(content) ->
          Enum.flat_map(content, fn
            %{"type" => "tool_result", "content" => result_content, "tool_use_id" => _id} ->
              result_text = tool_result_recap_text(result_content)

              if String.trim(result_text) == "sent" do
                []
              else
                [{:result, String.slice(result_text, 0, 500)}]
              end

            _ ->
              []
          end)

        _ ->
          []
      end)

    if entries == [] do
      ""
    else
      lines =
        Enum.map(entries, fn
          {:call, name, snippet} -> "-> " <> name <> ": " <> snippet
          {:result, text} -> "   <- " <> String.slice(text, 0, 500)
        end)

      ago = NaiveDateTime.diff(NaiveDateTime.utc_now(), session.inserted_at, :minute)

      "<previous_cycle id=\"" <>
        session.cycle_id <>
        "\" minutes_ago=\"" <>
        Integer.to_string(ago) <>
        "\">\n" <>
        Enum.join(lines, "\n") <>
        "\n</previous_cycle>"
    end
  end

  defp recap_tool_snippet(name, input) when is_map(input) do
    case name do
      "read_log" ->
        from = inspect(input["from_date"] || "")
        to = inspect(input["to_date"] || "")
        "from=#{from} to=#{to}"

      "search" ->
        terms = input["query"] || []
        "query=" <> inspect(Enum.take(terms, 5))

      "view_analysis" ->
        ids = input["ids"] || []
        "ids=" <> inspect(Enum.take(ids, 10))

      "look" ->
        "msg=" <> inspect(input["message_id"])

      other ->
        keys =
          input
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.take(6)

        "#{other} keys=" <> inspect(keys)
    end
  end

  defp recap_tool_snippet(name, _), do: "#{name}"

  defp tool_result_recap_text(content) when is_binary(content), do: content

  defp tool_result_recap_text(content) when is_list(content) do
    Enum.map_join(content, "\n", &tool_result_block_text/1)
  end

  defp tool_result_recap_text(content),
    do: inspect(content, limit: 50, printable_limit: 2000)

  defp tool_result_block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"type" => type}) when is_binary(type), do: "[#{type}]"
  defp tool_result_block_text(other), do: inspect(other, limit: 20, printable_limit: 300)

  defp send_agent_response(
         %{chat_id: chat_id, reply_to: reply_to, bot_config: bc} = state,
         content
       )
       when is_integer(chat_id) do
    text = extract_text(content)

    if text != "" do
      case BotAdapter.send_message(bc.session_id, chat_id, text, reply_to: reply_to) do
        {:ok, sent} ->
          track_sent_message(state, sent, text)

        {:error, reason} ->
          put_last_tool_error(state, inspect(reason))
      end
    else
      state
    end
  end

  defp send_agent_response(state, _), do: state

  defp track_sent_message(state, sent, text) when is_map(state) and is_binary(text) do
    base = %{state | cycle_replied?: true, last_sent_message_text: text}

    case sent_message_id(sent) do
      id when is_integer(id) ->
        %{base | last_sent_message_id: id}

      _ ->
        base
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

  defp commit_stream_usage(%{stream_usage_current: usage} = state)
       when is_map(usage) and map_size(usage) > 0 do
    turn_cost = estimate_usage_cost_usd(usage, state.bot_config && state.bot_config.model) || 0.0

    %{
      state
      | cycle_usage_total: merge_usage_maps(state.cycle_usage_total, usage),
        cycle_cost_usd: state.cycle_cost_usd + turn_cost,
        stream_usage_current: %{}
    }
  end

  defp commit_stream_usage(state), do: state

  defp merge_usage_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        is_map(left_value) and is_map(right_value) ->
          merge_usage_maps(left_value, right_value)

        is_integer(left_value) and is_integer(right_value) ->
          left_value + right_value

        true ->
          right_value
      end
    end)
  end

  defp merge_usage_maps(_left, right) when is_map(right), do: right
  defp merge_usage_maps(left, _right) when is_map(left), do: left
  defp merge_usage_maps(_left, _right), do: %{}

  defp maybe_append_cycle_footer(
         %{cycle_replied?: true, chat_id: chat_id, bot_config: bc} = state
       )
       when is_integer(chat_id) do
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

  defp build_cycle_cost_footer(state) do
    usage = state.cycle_usage_total || %{}
    total_in = total_input_tokens(usage)
    total_out = usage_int(usage["output_tokens"])

    if total_in <= 0 and total_out <= 0 do
      nil
    else
      elapsed_seconds = cycle_elapsed_seconds(state.cycle_started_ms)
      duration = format_seconds(elapsed_seconds)
      in_part = format_tokens_k(total_in)
      out_part = format_tokens_k(total_out)

      usd =
        if state.cycle_cost_usd > 0 do
          state.cycle_cost_usd
        else
          estimate_usage_cost_usd(usage, state.bot_config && state.bot_config.model) || 0.0
        end

      cost = "$" <> :erlang.float_to_binary(usd, decimals: 3)
      "[#{duration} | #{in_part} in | #{out_part} out | #{cost}]"
    end
  end

  defp cycle_elapsed_seconds(started_ms) when is_integer(started_ms) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    max(elapsed_ms, 0) / 1000
  end

  defp cycle_elapsed_seconds(_), do: 0.0

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

  defp estimate_usage_cost_usd(usage, model) when is_map(usage) do
    case model_pricing_rates(model, prompt_over_200k?(usage)) do
      nil ->
        nil

      rates ->
        input_tokens = usage_int(usage["input_tokens"])
        output_tokens = usage_int(usage["output_tokens"])
        cache_creation_tokens = usage_int(usage["cache_creation_input_tokens"])
        cache_read_tokens = usage_int(usage["cache_read_input_tokens"])

        (input_tokens * rates.input +
           output_tokens * rates.output +
           cache_creation_tokens * rates.cache_write +
           cache_read_tokens * rates.cache_read) / 1_000_000
    end
  end

  defp estimate_usage_cost_usd(_usage, _model), do: nil

  defp prompt_over_200k?(usage) when is_map(usage) do
    total_input_tokens(usage) > 200_000
  end

  defp prompt_over_200k?(_usage), do: false

  # Source-of-truth rates (USD / MTok) from https://claude.com/pricing,
  # synced on 2026-02-27.
  defp model_pricing_rates(model, over_200k?) when is_binary(model) do
    downcased = String.downcase(model)

    cond do
      String.contains?(downcased, "opus-4-6") ->
        if over_200k? do
          %{input: 10.0, output: 37.5, cache_write: 12.5, cache_read: 1.0}
        else
          %{input: 5.0, output: 25.0, cache_write: 6.25, cache_read: 0.5}
        end

      String.contains?(downcased, "sonnet-4-6") ->
        if over_200k? do
          %{input: 6.0, output: 22.5, cache_write: 7.5, cache_read: 0.6}
        else
          %{input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3}
        end

      String.contains?(downcased, "haiku-4-5") ->
        %{input: 1.0, output: 5.0, cache_write: 1.25, cache_read: 0.1}

      String.contains?(downcased, "opus-4-5") ->
        %{input: 5.0, output: 25.0, cache_write: 6.25, cache_read: 0.5}

      String.contains?(downcased, "sonnet-4-5") ->
        %{input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3}

      String.contains?(downcased, "opus-4-1") ->
        %{input: 15.0, output: 75.0, cache_write: 18.75, cache_read: 1.5}

      String.contains?(downcased, "sonnet-4") ->
        %{input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3}

      String.contains?(downcased, "opus-4") ->
        %{input: 15.0, output: 75.0, cache_write: 18.75, cache_read: 1.5}

      String.contains?(downcased, "sonnet-3-7") ->
        %{input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3}

      String.contains?(downcased, "sonnet-3-5") ->
        %{input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3}

      String.contains?(downcased, "haiku-3-5") ->
        %{input: 0.8, output: 4.0, cache_write: 1.0, cache_read: 0.08}

      String.contains?(downcased, "opus-3") ->
        %{input: 15.0, output: 75.0, cache_write: 18.75, cache_read: 1.5}

      String.contains?(downcased, "haiku-3") ->
        %{input: 0.25, output: 1.25, cache_write: 0.30, cache_read: 0.03}

      true ->
        nil
    end
  end

  defp model_pricing_rates(_model, _over_200k?), do: nil

  defp extract_text(%{"_wrapped" => value}) when is_binary(value), do: value

  defp extract_text(%{"_wrapped" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_text(content) when is_map(content) do
    case content["text"] do
      t when is_binary(t) -> t
      _ -> ""
    end
  end

  defp extract_text(_), do: ""

  defp maybe_track_tool_error(state, {:error, reason}) when is_binary(reason) do
    put_last_tool_error(state, reason)
  end

  defp maybe_track_tool_error(state, {:error, reason}) do
    put_last_tool_error(state, inspect(reason))
  end

  defp maybe_track_tool_error(state, _), do: state

  defp maybe_capture_tool_error(state, content) do
    case extract_tool_error(content) do
      nil -> state
      error -> put_last_tool_error(state, error)
    end
  end

  defp extract_tool_error(%{"_wrapped" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "tool_result", "is_error" => true, "content" => content}
      when is_binary(content) ->
        content

      _ ->
        nil
    end)
  end

  defp extract_tool_error(_), do: nil

  defp put_last_tool_error(state, error) when is_binary(error) do
    error =
      error
      |> String.trim()
      |> String.slice(0, 1200)

    if error == "" do
      state
    else
      %{state | last_tool_error: error}
    end
  end

  defp put_last_tool_error(state, _), do: state

  defp maybe_send_silent_cycle_fallback(%{cycle_replied?: true} = state), do: state

  defp maybe_send_silent_cycle_fallback(%{chat_id: chat_id, bot_config: bc} = state)
       when is_integer(chat_id) do
    _ =
      BotAdapter.send_message(
        bc.session_id,
        chat_id,
        fallback_cycle_message(state.last_tool_error),
        reply_to: state.reply_to
      )

    state
  end

  defp maybe_send_silent_cycle_fallback(state), do: state

  defp fallback_cycle_message(nil) do
    "I ran into an internal error and stopped before replying. Please ask me again."
  end

  defp fallback_cycle_message(error) when is_binary(error) do
    line =
      error
      |> String.split("\n")
      |> List.first()
      |> to_string()
      |> String.trim()
      |> String.slice(0, 400)

    if line == "" do
      fallback_cycle_message(nil)
    else
      "I hit a tool error and stopped before replying.\n\n#{line}"
    end
  end

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
