defmodule Froth.Tools.Support do
  @moduledoc false

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.Surface
  alias Froth.Telegram.Bot.Config, as: BotConfig

  @default_session_id "charlie"

  def chat_id(%Context{surface: %Surface{chat_id: id}}) when is_integer(id),
    do: id

  def chat_id(_ctx), do: 0

  def session_id(%Context{surface: %Surface{session_id: id}})
      when is_binary(id), do: id

  def session_id(_ctx), do: @default_session_id

  def bot_id(%Context{bot_config: %BotConfig{id: id}}) when is_binary(id),
    do: id

  def bot_id(_ctx), do: "charlie"

  def reply_to(%Context{surface: %Surface{reply_to: reply_to}})
      when is_integer(reply_to),
      do: reply_to

  def reply_to(_ctx), do: nil

  def maybe_put_eval_topic(eval_opts, %Context{cycle_id: cycle_id})
      when is_binary(cycle_id) and cycle_id != "" do
    Keyword.put(eval_opts, :topic, "cycle:#{cycle_id}")
  end

  def maybe_put_eval_topic(eval_opts, _ctx), do: eval_opts

  def maybe_put_eval_telegram(
        eval_opts,
        %Context{
          bot_config: %BotConfig{id: bot_id},
          surface: %Surface{chat_id: chat_id}
        }
      )
      when is_binary(bot_id) and is_integer(chat_id) do
    Keyword.put(eval_opts, :telegram, %{bot_id: bot_id, chat_id: chat_id})
  end

  def maybe_put_eval_telegram(eval_opts, _ctx), do: eval_opts

  def format_task_elapsed(%{started_at: nil}), do: ""

  def format_task_elapsed(%{finished_at: finished_at, started_at: started_at})
      when not is_nil(finished_at) do
    seconds = DateTime.diff(finished_at, started_at, :second)
    "(#{format_duration(seconds)})"
  end

  def format_task_elapsed(%{started_at: started_at}) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
    "(#{format_duration(seconds)})"
  end

  def eval_session_id(%{"session_id" => session_id})
      when is_binary(session_id) and session_id != "" do
    session_id
  end

  def eval_session_id(_input), do: nil

  def required_trimmed_string(input, key)
      when is_map(input) and is_binary(key) do
    case optional_trimmed_string(input, key) do
      {:ok, nil} -> {:error, "#{key} must be a non-empty string"}
      other -> other
    end
  end

  def optional_trimmed_string(input, key)
      when is_map(input) and is_binary(key) do
    case Map.get(input, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = String.trim(value)
        {:ok, if(trimmed == "", do: nil, else: trimmed)}

      _value ->
        {:error, "#{key} must be a string"}
    end
  end

  def working_dir(input) when is_map(input) do
    case input["working_dir"] do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> File.cwd!()
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds),
    do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
end
