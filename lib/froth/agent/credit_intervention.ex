defmodule Froth.Agent.CreditIntervention do
  @moduledoc false

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.{BotAdapter, MessageIdSync, PendingAsk, PendingAsks}

  @kind "inference_credit_retry"
  @question "Insert coin."
  @alternative "Okay"
  @tool_use_id "inference_credit_retry"

  def credit_error?(reason) do
    reason
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> String.downcase()
    |> then(fn text ->
      String.contains?(text, "credit balance is too low") or
        String.contains?(text, "insufficient balance") or
        String.contains?(text, "insufficient credit")
    end)
  end

  def retry?(%PendingAsk{config: %{"kind" => @kind}}), do: true
  def retry?(_pending_ask), do: false

  def retry_answer, do: @alternative

  def maybe_post(reason, %Context{} = context) do
    if credit_error?(reason), do: post(context), else: :ignore
  end

  def maybe_post(_reason, _context), do: :ignore

  def maybe_finalize_message(%PendingAsk{} = pending_ask, session_id)
      when is_binary(session_id) do
    if retry?(pending_ask) and is_integer(pending_ask.message_id) do
      BotAdapter.edit_message_text(
        session_id,
        pending_ask.chat_id,
        pending_ask.message_id,
        @question <> "\n\n✓ " <> (pending_ask.answer || @alternative),
        reply_markup: empty_keyboard()
      )
    else
      :ok
    end
  end

  def maybe_finalize_message(_pending_ask, _session_id), do: :ok

  defp post(%Context{
         cycle_id: cycle_id,
         bot_config: %BotConfig{id: bot_id},
         surface: surface
       })
       when is_binary(cycle_id) and is_binary(bot_id) and
              is_binary(surface.session_id) and is_integer(surface.chat_id) do
    markup = %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => [
        [
          %{
            "@type" => "inlineKeyboardButton",
            "text" => @alternative,
            "type" => %{
              "@type" => "inlineKeyboardButtonTypeCallback",
              "data" => Base.encode64("ask:0")
            }
          }
        ]
      ]
    }

    case BotAdapter.send_message(
           surface.session_id,
           surface.chat_id,
           @question,
           reply_to: surface.reply_to,
           reply_markup: markup
         ) do
      {:ok, sent} ->
        with {:ok, message_id} <- sent_message_id(sent),
             pending_id =
               MessageIdSync.resolve(bot_id, surface.chat_id, message_id),
             {:ok, pending_ask} <-
               PendingAsks.create(%{
                 cycle_id: cycle_id,
                 bot_id: bot_id,
                 chat_id: surface.chat_id,
                 message_id: pending_id,
                 tool_use_id: @tool_use_id,
                 question: @question,
                 alternatives: [@alternative],
                 config: %{"kind" => @kind, "require_reply" => true}
               }) do
          {:ok,
           refresh_message_id(
             pending_ask,
             bot_id,
             surface.chat_id,
             message_id
           )}
        end

      error ->
        error
    end
  end

  defp post(_context), do: :ignore

  defp sent_message_id(%{"id" => id}) when is_integer(id), do: {:ok, id}

  defp sent_message_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :missing_message_id}
    end
  end

  defp sent_message_id(_sent), do: {:error, :missing_message_id}

  defp refresh_message_id(pending_ask, bot_id, chat_id, original_message_id) do
    resolved_message_id =
      MessageIdSync.resolve(bot_id, chat_id, original_message_id)

    if resolved_message_id != pending_ask.message_id do
      PendingAsks.sync_message_id(
        bot_id,
        chat_id,
        pending_ask.message_id,
        resolved_message_id
      )

      %{pending_ask | message_id: resolved_message_id}
    else
      pending_ask
    end
  end

  defp empty_keyboard,
    do: %{"@type" => "replyMarkupInlineKeyboard", "rows" => []}
end
