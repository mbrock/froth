defmodule Froth.Telegram.ToolExecution do
  @moduledoc false

  alias Froth.Agent.{FailureIntervention, Surface, ToolDescription, ToolUse}
  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Inference.Tools
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.{BotAdapter, ControlPrompt}

  @telegram_text_limit 4096

  # Spam suppressed — send_message is a no-op.
  def execute(%Context{spam: false, tool_call: %ToolUse{name: "send_message"}}) do
    %{result: {:ok, "suppressed"}}
  end

  # Telegram-side send_message with real surface.
  def execute(%Context{
        tool_call: %ToolUse{name: "send_message", input: %{"text" => text}},
        surface: %Surface{session_id: session_id, chat_id: chat_id, reply_to: reply_to}
      })
      when is_binary(text) and is_binary(session_id) and is_integer(chat_id) do
    case BotAdapter.send_message(session_id, chat_id, text, reply_to: reply_to) do
      {:ok, sent} ->
        %{result: {:ok, "sent"}, sent_message: %{sent: sent, text: text}}

      {:error, reason} ->
        %{result: {:error, inspect(reason)}}
    end
  end

  # Generic tool execution with a real Telegram chat: narrate to chat
  # and dispatch through `Tools.execute/4`.
  def execute(
        %Context{
          tool_call: %ToolUse{name: name, input: input} = tool_call,
          bot_config: %BotConfig{},
          surface: %Surface{session_id: session_id, chat_id: chat_id, reply_to: ctx_reply_to}
        } = ctx
      )
      when is_binary(name) and is_map(input) and is_binary(session_id) and is_integer(chat_id) do
    reply_to = Map.get(input, "reply_to") || Map.get(input, :reply_to) || ctx_reply_to
    narration_message = maybe_send_narration(ctx, reply_to)

    tool_opts = tool_opts_from(ctx)
    result = Tools.execute(name, input, chat_id, tool_opts)

    case FailureIntervention.maybe_intervene(result, ctx) do
      %{result: _} = outcome ->
        Map.put(outcome, :narration_message, narration_message)

      updated_result ->
        build_tool_outcome(updated_result, narration_message, tool_call.input)
    end
  end

  # Headless fallback for paths without a Telegram chat (e.g.
  # `Agent.run_adhoc/2` from a cron or script). Skip narration and
  # Telegram-side effects entirely; invoke the tool directly with
  # chat_id=0 (tools that require a real chat_id return errors).
  def execute(%Context{tool_call: %ToolUse{name: name, input: input}} = ctx)
      when is_binary(name) and is_map(input) do
    chat_id =
      case ctx.surface do
        %Surface{chat_id: id} when is_integer(id) -> id
        _ -> 0
      end

    tool_opts = tool_opts_from(ctx)

    result =
      name
      |> Tools.execute(input, chat_id, tool_opts)
      |> FailureIntervention.maybe_intervene(ctx)

    case result do
      %{result: _} = outcome -> outcome
      other -> %{result: other}
    end
  end

  def execute(_ctx), do: %{result: {:error, "invalid tool execution context"}}

  # --- Tool opts projection ---

  # Build the `Keyword.t()` of opts `Tools.execute/4` expects, drawing
  # from the Context's structured sub-parts. Nil-skips are centralised
  # via `maybe_put_tool_opt/3` so the two clauses above share one
  # projection instead of duplicating 15 `maybe_put` lines each.
  defp tool_opts_from(%Context{} = ctx) do
    bc = ctx.bot_config
    surface = ctx.surface
    view = ctx.view
    tool_call = ctx.tool_call

    []
    |> maybe_put_tool_opt(:cycle_id, ctx.cycle_id)
    |> maybe_put_tool_opt(:tool_use_id, tool_call && tool_call.id)
    |> maybe_put_tool_opt(:bot_id, bc && bc.id)
    |> maybe_put_tool_opt(:bot_username, bc && bc.bot_username)
    |> maybe_put_tool_opt(:session_id, surface && surface.session_id)
    |> maybe_put_tool_opt(:reply_to, surface && surface.reply_to)
    |> maybe_put_tool_opt(:spam, ctx.spam)
    |> maybe_put_tool_opt(:topic, tool_call && Map.get(tool_call.input, "topic"))
    |> maybe_put_tool_opt(:active_task_ids, view && view.active_task_ids)
    |> maybe_put_tool_opt(:system_prompt, ctx.system_prompt)
    |> maybe_put_tool_opt(:tools, ctx.tool_specs)
    |> maybe_put_tool_opt(:model, bc && bc.model)
    |> maybe_put_tool_opt(:thinking, bc && bc.thinking)
    |> maybe_put_tool_opt(:effort, bc && bc.effort)
  end

  # --- Narration ---

  defp maybe_send_narration(%Context{spam: false}, _reply_to), do: nil

  defp maybe_send_narration(%Context{tool_call: %ToolUse{input: input}} = ctx, reply_to)
       when is_map(input) do
    case ToolDescription.text_from_input(input) do
      narration when is_binary(narration) and narration != "" ->
        send_or_edit_narration(ctx, reply_to, narration, :italic)

      _ ->
        maybe_send_legacy_narration(input, ctx, reply_to)
    end
  end

  defp maybe_send_legacy_narration(%{"narration_markdown" => narration}, ctx, reply_to)
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
             narration: %{message_id: message_id, text: current_text, mode: mode}
           }
         } = ctx,
         reply_to,
         narration,
         mode
       )
       when is_binary(session_id) and is_integer(chat_id) and is_integer(message_id) and
              is_binary(current_text) and narration != "" do
    combined = append_narration(current_text, narration)

    if String.length(combined) <= @telegram_text_limit do
      case edit_narration(session_id, chat_id, message_id, combined, mode) do
        {:ok, _sent} -> %{message_id: message_id, text: combined, mode: mode}
        {:error, _reason} -> send_new_narration(ctx, reply_to, narration, mode)
      end
    else
      send_new_narration(ctx, reply_to, narration, mode)
    end
  end

  # No existing narration — just post a fresh one.
  defp send_or_edit_narration(
         %Context{surface: %Surface{session_id: session_id, chat_id: chat_id}} = ctx,
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
    opts = [reply_markup: cycle_reply_markup(ctx)]

    result =
      case mode do
        :markdown -> BotAdapter.send_markdown(session_id, chat_id, reply_to, narration, opts)
        :italic -> BotAdapter.send_italic(session_id, chat_id, reply_to, narration, opts)
      end

    case result do
      {:ok, sent} -> build_narration_message(sent, narration, mode)
      {:error, _reason} -> nil
    end
  end

  defp cycle_reply_markup(%Context{cycle_id: cycle_id, bot_config: %BotConfig{id: bot_id} = bc})
       when is_binary(cycle_id) and is_binary(bot_id) do
    %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => [
        ControlPrompt.buttons(
          cycle_id: cycle_id,
          bot_id: bot_id,
          bot_username: bc.bot_username
        )
      ]
    }
  end

  defp cycle_reply_markup(_ctx), do: nil

  defp edit_narration(session_id, chat_id, message_id, narration, :markdown),
    do: BotAdapter.edit_message_markdown(session_id, chat_id, message_id, narration)

  defp edit_narration(session_id, chat_id, message_id, narration, :italic),
    do: BotAdapter.edit_message_italic(session_id, chat_id, message_id, narration)

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
         {:await, %{"sent_message" => sent_message, "message_text" => message_text} = data},
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

  defp maybe_put_tool_opt(keyword, _key, nil), do: keyword
  defp maybe_put_tool_opt(keyword, key, value), do: Keyword.put(keyword, key, value)
end
