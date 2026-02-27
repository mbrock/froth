defmodule Froth.Telegram.Bot do
  @moduledoc """
  Telegram bot runtime backed by `Froth.Agent` cycles.

  Supports mention/reply activation, automatic tool execution, and cycle stop
  controls for Telegram mini-app inspection.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, Message, ToolUse, Worker}
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Telegram.BotAdapter

  defstruct [
    :bot_config,
    :cycle,
    :worker_pid,
    :worker_ref,
    :chat_id,
    :reply_to,
    active_tasks: %{},
    control_prompt_cycles: MapSet.new()
  ]

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

    Logger.info(
      event: :bot_listening,
      bot_id: bot_config.id,
      session_id: bot_config.session_id,
      username: bot_config.bot_username
    )

    {:ok, %__MODULE__{bot_config: bot_config}}
  end

  @impl true
  def handle_info({:telegram_update, update}, state) do
    case route_update(update, state.bot_config) do
      {:mention, chat_id, reply_to, text} ->
        {:noreply, start_cycle(state, chat_id, reply_to, text)}

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
    send_agent_response(state, content)
    {:noreply, state}
  end

  def handle_info({:event, _event, %Message{}}, state) do
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
    if reason != :normal do
      Logger.error(
        event: :cycle_crashed,
        cycle_id: state.cycle && state.cycle.id,
        reason: inspect(reason)
      )
    end

    Logger.info(event: :cycle_finished, cycle_id: state.cycle && state.cycle.id)

    {:noreply,
     %{state | cycle: nil, worker_pid: nil, worker_ref: nil, chat_id: nil, reply_to: nil}}
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
    text = get_in(msg, ["content", "text", "text"]) || ""

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
        {:mention, chat_id, msg["id"], text}

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
        case Repo.one(
               from(m in "telegram_messages",
                 where: m.chat_id == ^chat_id and m.message_id == ^reply_msg_id,
                 select: m.sender_id
               )
             ) do
          ^bot_user_id -> true
          _ -> false
        end

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

    start_cycle(state, chat_id, reply_to, text)
  end

  defp start_cycle(state, chat_id, reply_to, text)
       when is_integer(chat_id) and is_integer(reply_to) and is_binary(text) do
    bc = state.bot_config

    if state.worker_pid do
      Logger.info(event: :cycle_busy, bot_id: bc.id, chat_id: chat_id)
      BotAdapter.send_message(bc.session_id, chat_id, "(busy, try again in a moment)")
      state
    else
      BotAdapter.send_typing(bc.session_id, chat_id)

      message = Repo.insert!(%Message{role: :user, content: Message.wrap(text)})
      cycle = Repo.insert!(%Cycle{})
      Repo.insert!(%Agent.Event{cycle_id: cycle.id, head_id: message.id, seq: 0})

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

      Logger.info(event: :cycle_started, bot_id: bc.id, cycle_id: cycle.id, chat_id: chat_id)

      %{
        state
        | cycle: cycle,
          worker_pid: pid,
          worker_ref: ref,
          chat_id: chat_id,
          reply_to: reply_to
      }
    end
  end

  defp start_cycle(state, _chat_id, _reply_to, _text), do: state

  defp stop_cycle(state, cycle_id, opts) when is_binary(cycle_id) do
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
            reply_to: nil
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

            result =
              case BotAdapter.send_message(bc.session_id, chat_id, text, reply_to: reply_to) do
                {:ok, _sent} -> {:ok, "sent"}
                {:error, reason} -> {:error, inspect(reason)}
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

      state = maybe_track_task_from_result(state, cycle_id, result)
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

  defp send_agent_response(%{chat_id: chat_id, reply_to: reply_to, bot_config: bc}, content)
       when is_integer(chat_id) do
    text = extract_text(content)

    if text != "" do
      BotAdapter.send_message(bc.session_id, chat_id, text, reply_to: reply_to)
    end
  end

  defp send_agent_response(_, _), do: :ok

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
end
