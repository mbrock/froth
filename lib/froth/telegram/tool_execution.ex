defmodule Froth.Telegram.ToolExecution do
  @moduledoc false

  alias Froth.Inference.Tools
  alias Froth.Telegram.BotAdapter

  def execute(%{
        name: "send_message",
        input: %{"text" => text},
        session_id: session_id,
        chat_id: chat_id,
        reply_to: reply_to
      })
      when is_binary(text) and is_binary(session_id) and is_integer(chat_id) do
    case BotAdapter.send_message(session_id, chat_id, text, reply_to: reply_to) do
      {:ok, sent} ->
        %{
          result: {:ok, "sent"},
          sent_message: %{
            sent: sent,
            text: text
          }
        }

      {:error, reason} ->
        %{result: {:error, inspect(reason)}}
    end
  end

  def execute(
        %{
          name: name,
          input: input,
          session_id: session_id,
          bot_id: bot_id,
          chat_id: chat_id
        } = execution
      )
      when is_binary(name) and is_map(input) and is_binary(session_id) and is_binary(bot_id) and
             is_integer(chat_id) do
    reply_to = Map.get(input, "reply_to") || Map.get(input, :reply_to) || execution[:reply_to]

    maybe_send_control_prompt(name, input)
    maybe_send_narration(input, session_id, chat_id, reply_to)

    result =
      case name do
        "elixir_eval" ->
          Tools.execute(
            name,
            input,
            chat_id,
            bot_id: bot_id,
            session_id: session_id,
            topic: input["topic"]
          )

        "run_shell" ->
          Tools.execute(name, input, chat_id, bot_id: bot_id, session_id: session_id)

        _ ->
          Tools.execute(name, input, chat_id, bot_id: bot_id, session_id: session_id)
      end

    %{result: normalize_result(result)}
  end

  def execute(_prepared), do: %{result: {:error, "invalid tool execution context"}}

  defp maybe_send_control_prompt(
         "elixir_eval",
         %{
           "send_control_prompt" => true,
           "control_prompt" => %{
             "session_id" => session_id,
             "chat_id" => chat_id,
             "reply_to" => reply_to,
             "text" => text,
             "reply_markup" => reply_markup
           }
         }
       ) do
    _ =
      BotAdapter.send_message(
        session_id,
        chat_id,
        text,
        reply_to: reply_to,
        reply_markup: reply_markup
      )

    :ok
  end

  defp maybe_send_control_prompt(
         "run_shell",
         %{
           "send_control_prompt" => true,
           "control_prompt" => %{
             "session_id" => session_id,
             "chat_id" => chat_id,
             "reply_to" => reply_to,
             "text" => text,
             "reply_markup" => reply_markup
           }
         }
       ) do
    _ =
      BotAdapter.send_message(
        session_id,
        chat_id,
        text,
        reply_to: reply_to,
        reply_markup: reply_markup
      )

    :ok
  end

  defp maybe_send_control_prompt(_name, _input), do: :ok

  defp maybe_send_narration(%{"narration" => narration}, session_id, chat_id, reply_to)
       when is_binary(narration) and narration != "" and is_binary(session_id) and
              is_integer(chat_id) do
    _ = BotAdapter.send_italic(session_id, chat_id, reply_to, narration)
    :ok
  end

  defp maybe_send_narration(_input, _session_id, _chat_id, _reply_to), do: :ok

  defp normalize_result({:yield, reason}), do: {:yield, reason}
  defp normalize_result(result), do: result
end
