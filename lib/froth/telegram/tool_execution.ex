defmodule Froth.Telegram.ToolExecution do
  @moduledoc false

  alias Froth.Agent.{
    CycleRuntime,
    FailureIntervention,
    Surface,
    ToolDescription,
    ToolUse
  }

  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Inference.Tools
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.{BotAdapter, ControlPrompt}

  @telegram_text_limit 4096

  # Spam suppressed — send_message is a no-op.
  def execute(%Context{spam: false}, %ToolUse{name: "send_message"}) do
    %{result: {:ok, "suppressed"}}
  end

  # Telegram-side send_message with real surface.
  def execute(
        %Context{
          surface: %Surface{
            session_id: session_id,
            chat_id: chat_id,
            reply_to: reply_to
          }
        },
        %ToolUse{name: "send_message", input: %{"text" => text}}
      )
      when is_binary(text) and is_binary(session_id) and is_integer(chat_id) do
    case send_markdown_message(session_id, chat_id, reply_to, text) do
      {:ok, sent} ->
        %{result: {:ok, "sent"}, sent_message: %{sent: sent, text: text}}

      {:error, reason} ->
        %{result: {:error, inspect(reason)}}
    end
  end

  # Generic tool execution with a real Telegram chat: narrate to chat
  # and dispatch through `Tools.execute/3`.
  def execute(
        %Context{
          bot_config: %BotConfig{},
          surface: %Surface{
            session_id: session_id,
            chat_id: chat_id,
            reply_to: ctx_reply_to
          }
        } = ctx,
        %ToolUse{name: name, input: input} = tool_call
      )
      when is_binary(name) and is_map(input) and is_binary(session_id) and
             is_integer(chat_id) do
    reply_to =
      Map.get(input, "reply_to") || Map.get(input, :reply_to) || ctx_reply_to

    narration_message = maybe_send_narration(ctx, tool_call, reply_to)
    control_message = maybe_control_message(ctx, narration_message)

    CycleRuntime.record_tool_narration(
      ctx.cycle_id,
      tool_call.id,
      narration_message,
      control_message
    )

    result = Tools.execute(ctx, tool_call)

    case FailureIntervention.maybe_intervene(result, ctx, tool_call) do
      %{result: _} = outcome ->
        outcome
        |> Map.put(:narration_message, narration_message)
        |> Map.put(:control_message, control_message)

      updated_result ->
        updated_result
        |> build_tool_outcome(narration_message, input)
        |> Map.put(:control_message, control_message)
    end
  end

  # Headless fallback for paths without a Telegram chat (e.g. a cycle
  # started directly via `CycleRuntime.run_to_completion/1` from a cron
  # or script). Skip narration and Telegram-side effects entirely;
  # invoke the tool directly.
  def execute(
        %Context{} = ctx,
        %ToolUse{name: name, input: input} = tool_call
      )
      when is_binary(name) and is_map(input) do
    result =
      ctx
      |> Tools.execute(tool_call)
      |> FailureIntervention.maybe_intervene(ctx, tool_call)

    case result do
      %{result: _} = outcome -> outcome
      other -> %{result: other}
    end
  end

  def execute(_ctx, _tool_call),
    do: %{result: {:error, "invalid tool execution context"}}

  # Model-authored send_message content may contain Markdown. Prefer TDLib's
  # parser, but preserve the historical plain-text behavior if the markup is
  # malformed.
  defp send_markdown_message(session_id, chat_id, reply_to, text) do
    case BotAdapter.send_markdown(session_id, chat_id, reply_to, text) do
      {:error, _reason} ->
        BotAdapter.send_message(session_id, chat_id, text, reply_to: reply_to)

      result ->
        result
    end
  end

  # --- Narration ---

  defp maybe_send_narration(%Context{spam: false}, _tool_call, _reply_to),
    do: nil

  # A parallel sibling already owns the first-control reservation. Suppress
  # this sibling's chat narration instead of creating a second, uncontrolled
  # work message. Its execution remains visible in the shared mini app.
  defp maybe_send_narration(
         %Context{
           view: %View{control_message: nil, control_reservation: reservation}
         },
         _tool_call,
         _reply_to
       )
       when is_binary(reservation),
       do: nil

  defp maybe_send_narration(
         %Context{} = ctx,
         %ToolUse{input: input},
         reply_to
       )
       when is_map(input) do
    case ToolDescription.text_from_input(input) do
      narration when is_binary(narration) and narration != "" ->
        send_or_edit_narration(ctx, reply_to, narration, :italic)

      _ ->
        maybe_send_legacy_narration(input, ctx, reply_to)
    end
  end

  defp maybe_send_legacy_narration(
         %{"narration_markdown" => narration},
         ctx,
         reply_to
       )
       when is_binary(narration) and narration != "" do
    send_or_edit_narration(ctx, reply_to, String.trim(narration), :markdown)
  end

  defp maybe_send_legacy_narration(%{"narration" => narration}, ctx, reply_to)
       when is_binary(narration) and narration != "" do
    send_or_edit_narration(ctx, reply_to, String.trim(narration), :italic)
  end

  defp maybe_send_legacy_narration(_input, _ctx, _reply_to), do: nil

  # Existing narration message — try editing in place before falling
  # back to a fresh post.
  defp send_or_edit_narration(
         %Context{
           surface: %Surface{session_id: session_id, chat_id: chat_id},
           view: %View{
             narration: %{
               message_id: message_id,
               text: current_text,
               mode: mode
             }
           }
         } = ctx,
         reply_to,
         narration,
         mode
       )
       when is_binary(session_id) and is_integer(chat_id) and
              is_integer(message_id) and
              is_binary(current_text) and narration != "" do
    combined = append_narration(current_text, narration)

    if String.length(combined) <= @telegram_text_limit do
      case edit_narration(session_id, chat_id, message_id, combined, mode) do
        {:ok, _sent} ->
          %{message_id: message_id, text: combined, mode: mode}

        {:error, _reason} ->
          send_new_narration(ctx, reply_to, narration, mode)
      end
    else
      send_new_narration(ctx, reply_to, narration, mode)
    end
  end

  # No existing narration — just post a fresh one.
  defp send_or_edit_narration(
         %Context{surface: %Surface{session_id: session_id, chat_id: chat_id}} =
           ctx,
         reply_to,
         narration,
         mode
       )
       when is_binary(session_id) and is_integer(chat_id) and narration != "" do
    send_new_narration(ctx, reply_to, narration, mode)
  end

  defp send_or_edit_narration(_, _, _, _), do: nil

  defp send_new_narration(%Context{} = ctx, reply_to, narration, mode) do
    %Surface{session_id: session_id, chat_id: chat_id} = ctx.surface

    opts = maybe_cycle_reply_markup(ctx)

    result =
      case mode do
        :markdown ->
          BotAdapter.send_markdown(
            session_id,
            chat_id,
            reply_to,
            narration,
            opts
          )

        :italic ->
          BotAdapter.send_italic(
            session_id,
            chat_id,
            reply_to,
            narration,
            opts
          )
      end

    case result do
      {:ok, sent} -> build_narration_message(sent, narration, mode)
      {:error, _reason} -> nil
    end
  end

  defp cycle_reply_markup(%Context{
         cycle_id: cycle_id,
         bot_config: %BotConfig{id: bot_id} = bc
       })
       when is_binary(cycle_id) and is_binary(bot_id) do
    ControlPrompt.reply_markup(
      cycle_id: cycle_id,
      bot_id: bot_id,
      bot_username: bc.bot_username
    )
  end

  defp cycle_reply_markup(_ctx), do: nil

  defp maybe_cycle_reply_markup(%Context{
         view: %View{control_message: nil, control_reservation: reservation}
       })
       when is_binary(reservation),
       do: []

  defp maybe_cycle_reply_markup(%Context{} = ctx),
    do: [reply_markup: cycle_reply_markup(ctx)]

  defp maybe_control_message(_ctx, nil), do: nil

  defp maybe_control_message(
         %Context{
           view: %View{control_message: nil, control_reservation: nil}
         },
         message
       ),
       do: message

  defp maybe_control_message(
         %Context{
           view: %View{control_message: %{message_id: old_message_id}}
         },
         %{message_id: new_message_id} = message
       )
       when old_message_id != new_message_id,
       do: message

  defp maybe_control_message(_ctx, _message), do: nil

  defp edit_narration(session_id, chat_id, message_id, narration, :markdown),
    do:
      BotAdapter.edit_message_markdown(
        session_id,
        chat_id,
        message_id,
        narration
      )

  defp edit_narration(session_id, chat_id, message_id, narration, :italic),
    do:
      BotAdapter.edit_message_italic(
        session_id,
        chat_id,
        message_id,
        narration
      )

  defp build_narration_message(sent, text, mode) when is_binary(text) do
    case sent_message_id(sent) do
      id when is_integer(id) -> %{message_id: id, text: text, mode: mode}
      _ -> nil
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

  defp append_narration(current_text, narration) do
    existing = String.trim_trailing(current_text)
    addition = String.trim(narration)

    cond do
      existing == "" -> addition
      addition == "" -> existing
      true -> existing <> "\n" <> addition
    end
  end

  defp build_tool_outcome(
         {:await, %{"sent_message" => sent_message} = data},
         narration_message,
         %{"question" => question}
       )
       when is_map(sent_message) and is_binary(question) do
    %{
      result: {:await, Map.delete(data, "sent_message")},
      sent_message: %{sent: sent_message, text: question},
      narration_message: narration_message,
      awaiting_user_input: true
    }
  end

  defp build_tool_outcome(
         {:await,
          %{"sent_message" => sent_message, "message_text" => message_text} =
            data},
         narration_message,
         _input
       )
       when is_map(sent_message) and is_binary(message_text) do
    %{
      result: {:await, Map.delete(data, "sent_message")},
      sent_message: %{sent: sent_message, text: message_text},
      narration_message: narration_message,
      awaiting_user_input: true
    }
  end

  defp build_tool_outcome(result, narration_message, _input) do
    %{result: normalize_result(result), narration_message: narration_message}
  end

  defp normalize_result({:await, data}), do: {:await, data}
  defp normalize_result({:yield, reason}), do: {:yield, reason}
  defp normalize_result(result), do: result
end
