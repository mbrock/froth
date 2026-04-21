defmodule Froth.Tools.Ask do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.{Surface, ToolUse}
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.BotAdapter
  alias Froth.Tools.PendingAskSupport
  alias Froth.Tools.Support

  @impl true
  def name, do: "ask"

  @impl true
  def label, do: "ask user"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Ask the human a question and pause the current agent cycle until they answer. Use this only when you are genuinely blocked on missing preference, permission, or context that you cannot resolve from the chat log or the live system. The tool sends the question into Telegram, optionally renders inline choice buttons, and then resumes the same cycle with the user's answer as a string. The human can either press a button or reply in free text, so alternatives should be concise suggestions, not an exhaustive protocol.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "question" => %{
            "type" => "string",
            "description" =>
              "The question to ask. Keep it concrete and answerable in one reply."
          },
          "alternatives" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Optional short suggested answers to render as inline keyboard buttons. The user may still answer with free-form text instead."
          }
        },
        "required" => ["question"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(
        %Context{
          surface: %Surface{
            session_id: session_id,
            chat_id: chat_id,
            reply_to: reply_to
          },
          bot_config: %BotConfig{id: bot_id},
          cycle_id: cycle_id,
          system_prompt: system_prompt
        } = ctx,
        %ToolUse{id: tool_use_id, input: input},
        hooks
      )
      when is_binary(session_id) and is_integer(chat_id) and is_binary(bot_id) and
             is_binary(cycle_id) and is_binary(tool_use_id) and
             is_binary(system_prompt) and
             is_map(input) do
    with {:ok, question} <- Support.required_trimmed_string(input, "question"),
         {:ok, alternatives} <-
           PendingAskSupport.normalize_ask_alternatives(
             Map.get(input, "alternatives")
           ) do
      send_message_fun =
        Keyword.get(hooks, :send_message_fun, &BotAdapter.send_message/4)

      reply_markup = PendingAskSupport.ask_reply_markup(alternatives)

      send_opts =
        [reply_to: reply_to]
        |> PendingAskSupport.maybe_put_send_message_opt(
          :reply_markup,
          reply_markup
        )

      case send_message_fun.(session_id, chat_id, question, send_opts) do
        {:ok, sent} ->
          config = PendingAskSupport.session_config(ctx)

          with {:ok, message_id} <- PendingAskSupport.message_id(sent),
               {:ok, pending_ask} <-
                 PendingAskSupport.create_pending_ask(
                   %{
                     cycle_id: cycle_id,
                     bot_id: bot_id,
                     chat_id: chat_id,
                     message_id: message_id,
                     tool_use_id: tool_use_id,
                     question: question,
                     alternatives: alternatives,
                     config: config
                   },
                   bot_id,
                   chat_id,
                   message_id
                 ) do
            {:await,
             %{
               "kind" => "ask",
               "reason" => "Waiting for the user's answer.",
               "pending_ask_id" => pending_ask.id,
               "question_message_id" => pending_ask.message_id,
               "sent_message" => sent
             }}
          else
            {:error, reason} ->
              {:error, PendingAskSupport.format_error(reason)}
          end

        {:error, reason} ->
          {:error, PendingAskSupport.format_error(reason)}
      end
    end
  end

  def execute(_ctx, _tool_call, _hooks),
    do: {:error, "ask requires a full Telegram context"}
end
