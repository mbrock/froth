defmodule Froth.Telegram.EffectExecutor do
  @moduledoc """
  Telegram implementation of `Froth.Inference.EffectExecutor`.
  """

  @behaviour Froth.Inference.EffectExecutor

  alias Froth.Telegram.BotAdapter
  alias Froth.Telegram.ToolLoopPrompts

  @impl true
  def send_error(state, chat_id, message) when is_map(state) do
    BotAdapter.send_error(session_id(state), chat_id, message)
  end

  @impl true
  def send_italic(state, chat_id, reply_to, text) when is_map(state) do
    BotAdapter.send_italic(session_id(state), chat_id, reply_to, text)
  end

  @impl true
  def edit_message_italic(state, chat_id, message_id, text) when is_map(state) do
    BotAdapter.edit_message_italic(session_id(state), chat_id, message_id, text)
  end

  @impl true
  def send_typing(state, chat_id) when is_map(state) do
    BotAdapter.send_typing(session_id(state), chat_id)
  end

  @impl true
  def send_message(state, chat_id, text, opts) when is_map(state) and is_list(opts) do
    BotAdapter.send_message(session_id(state), chat_id, text, opts)
  end

  @impl true
  def send_or_edit_eval_prompt(state, inference_session, last_message_id) when is_map(state) do
    ToolLoopPrompts.send_or_edit_eval_prompt(
      session_id: session_id(state),
      bot_username: state.config.bot_username,
      inference_session_id: inference_session.id,
      chat_id: inference_session.chat_id,
      reply_to: inference_session.reply_to,
      last_message_id: last_message_id
    )
  end

  defp session_id(state), do: state.config.session_id
end
