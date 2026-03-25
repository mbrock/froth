defmodule Froth.Telegram.ToolExecution do
  @moduledoc false

  alias Froth.Inference.Tools
  alias Froth.Telegram.BotAdapter

  def execute(%{name: "send_message", spam: false}) do
    %{result: {:ok, "suppressed"}}
  end

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
          bot_username: bot_username,
          chat_id: chat_id
        } = execution
      )
      when is_binary(name) and is_map(input) and is_binary(session_id) and is_binary(bot_id) and
             is_integer(chat_id) do
    spam = Map.get(execution, :spam, true)
    reply_to = Map.get(input, "reply_to") || Map.get(input, :reply_to) || execution[:reply_to]

    tool_opts =
      [
        bot_id: bot_id,
        bot_username: bot_username,
        cycle_id: execution[:cycle_id],
        session_id: session_id,
        reply_to: execution[:reply_to]
      ]
      |> maybe_put_tool_opt(:spam, execution[:spam])
      |> maybe_put_tool_opt(:topic, input["topic"])

    maybe_send_control_prompt(name, input, spam)
    maybe_send_narration(input, session_id, chat_id, reply_to, spam)

    result =
      case name do
        "elixir_eval" ->
          Tools.execute(name, input, chat_id, tool_opts)

        "run_shell" ->
          Tools.execute(name, input, chat_id, tool_opts)

        _ ->
          Tools.execute(name, input, chat_id, tool_opts)
      end

    %{result: normalize_result(result)}
  end

  def execute(_prepared), do: %{result: {:error, "invalid tool execution context"}}

  defp maybe_send_control_prompt(_name, _input, false), do: :ok

  defp maybe_send_control_prompt(
         _name,
         %{"send_control_prompt" => true, "control_prompt" => %{} = control_prompt},
         true
       ) do
    send_control_prompt(control_prompt)
  end

  defp maybe_send_control_prompt(_name, _input, _spam), do: :ok

  defp send_control_prompt(%{
         "session_id" => session_id,
         "chat_id" => chat_id,
         "reply_to" => reply_to,
         "markdown" => markdown,
         "reply_markup" => reply_markup
       })
       when is_binary(session_id) and is_integer(chat_id) and is_binary(markdown) do
    _ =
      BotAdapter.send_markdown(
        session_id,
        chat_id,
        reply_to,
        markdown,
        reply_markup: reply_markup
      )

    :ok
  end

  defp send_control_prompt(%{
         "session_id" => session_id,
         "chat_id" => chat_id,
         "reply_to" => reply_to,
         "text" => text,
         "reply_markup" => reply_markup
       })
       when is_binary(session_id) and is_integer(chat_id) and is_binary(text) do
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

  defp send_control_prompt(_control_prompt), do: :ok

  defp maybe_send_narration(_input, _session_id, _chat_id, _reply_to, false), do: :ok

  defp maybe_send_narration(
         %{"narration_markdown" => narration},
         session_id,
         chat_id,
         reply_to,
         true
       )
       when is_binary(narration) and narration != "" and is_binary(session_id) and
              is_integer(chat_id) do
    _ = BotAdapter.send_markdown(session_id, chat_id, reply_to, narration)
    :ok
  end

  defp maybe_send_narration(%{"narration" => narration}, session_id, chat_id, reply_to, true)
       when is_binary(narration) and narration != "" and is_binary(session_id) and
              is_integer(chat_id) do
    _ = BotAdapter.send_italic(session_id, chat_id, reply_to, narration)
    :ok
  end

  defp maybe_send_narration(_input, _session_id, _chat_id, _reply_to, _spam), do: :ok

  defp normalize_result({:yield, reason}), do: {:yield, reason}
  defp normalize_result(result), do: result

  defp maybe_put_tool_opt(keyword, _key, nil), do: keyword
  defp maybe_put_tool_opt(keyword, key, value), do: Keyword.put(keyword, key, value)
end
