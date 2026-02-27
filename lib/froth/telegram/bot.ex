defmodule Froth.Telegram.Bot do
  @moduledoc """
  Minimal Telegram bot backed by the Agent framework.
  Subscribes to updates, starts agentic cycles on mention, sends replies.
  """

  use GenServer
  require Logger

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, Message, Worker}
  alias Froth.Repo
  alias Froth.Telegram.BotAdapter

  defstruct [:bot_config, :cycle, :worker_pid, :worker_ref, :chat_id, :reply_to]

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name, Module.concat(__MODULE__, String.capitalize(id)))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    bot_config = %{
      session_id: Keyword.fetch!(opts, :session_id),
      bot_username: Keyword.fetch!(opts, :bot_username),
      bot_user_id: Keyword.fetch!(opts, :bot_user_id),
      owner_user_id: Keyword.fetch!(opts, :owner_user_id),
      model: Keyword.get(opts, :model, "claude-opus-4-6"),
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful assistant on Telegram."),
      name_triggers: Keyword.get(opts, :name_triggers, [])
    }

    :ok = BotAdapter.subscribe(bot_config.session_id)

    Logger.info(
      event: :bot_listening,
      session_id: bot_config.session_id,
      username: bot_config.bot_username
    )

    {:ok, %__MODULE__{bot_config: bot_config}}
  end

  @impl true
  def handle_info({:telegram_update, update}, state) do
    case route(update, state.bot_config) do
      {:mention, chat_id, reply_to, text} ->
        {:noreply, start_cycle(state, chat_id, reply_to, text)}

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

  defp route(%{"@type" => "updateNewMessage", "message" => msg}, bot_config) do
    sender = get_in(msg, ["sender_id", "user_id"])
    chat_id = msg["chat_id"]
    text = get_in(msg, ["content", "text", "text"]) || ""

    cond do
      sender == bot_config.bot_user_id ->
        :ignore

      BotAdapter.mentioned?(msg, bot_config.bot_username, bot_config.bot_user_id, bot_config.name_triggers) and
          BotAdapter.allowed_chat?(chat_id, bot_config.owner_user_id, bot_config.session_id) ->
        {:mention, chat_id, msg["id"], text}

      true ->
        :ignore
    end
  end

  defp route(_, _), do: :ignore

  defp start_cycle(state, chat_id, reply_to, text) do
    bc = state.bot_config

    if state.worker_pid do
      Logger.info(event: :cycle_busy, chat_id: chat_id)
      BotAdapter.send_message(bc.session_id, chat_id, "(busy, try again in a moment)")
      state
    else
      BotAdapter.send_typing(bc.session_id, chat_id)

      message = Repo.insert!(%Message{role: :user, content: Message.wrap(text)})
      cycle = Repo.insert!(%Cycle{})
      Repo.insert!(%Agent.Event{cycle_id: cycle.id, head_id: message.id, seq: 0})

      config = %Config{
        system: bc.system_prompt,
        model: bc.model,
        tools: []
      }

      Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle.id}")
      {:ok, pid} = Worker.start_link({cycle, config})
      ref = Process.monitor(pid)

      Logger.info(event: :cycle_started, cycle_id: cycle.id, chat_id: chat_id)

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
