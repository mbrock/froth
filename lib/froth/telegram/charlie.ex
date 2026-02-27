defmodule Froth.Telegram.Charlie do
  @moduledoc """
  Charlie bot profile (identity + prompt config) backed by `Froth.Telegram.Bot`.
  """

  alias Froth.Inference.Tools
  alias Froth.Telegram.Bot
  alias Froth.Telegram.Profiles.CharliePrompt

  @default_bot_id "charlie"
  @default_bot_username "charliebuddybot"
  @default_session_id "charlie"
  @default_model "claude-opus-4-6"

  def default_config do
    cfg = Application.get_env(:froth, __MODULE__, [])

    %{
      id: @default_bot_id,
      bot_username: @default_bot_username,
      bot_user_id: Keyword.get(cfg, :bot_user_id, 0),
      owner_user_id: Keyword.get(cfg, :owner_user_id, 0),
      session_id: @default_session_id,
      model: @default_model,
      system_prompt_fun: &CharliePrompt.system_prompt/2,
      name_triggers: ["charlie"],
      tools: Tools.specs_for_api()
    }
  end

  def system_prompt(chat_id), do: system_prompt(chat_id, default_config())

  def system_prompt(chat_id, config) when is_map(config) do
    CharliePrompt.system_prompt(chat_id, config)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:id] || opts["id"] || "charlie"},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts \\ [])

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    config = build_config(opts)
    name = Keyword.get(opts, :name, __MODULE__)
    Bot.start_link(Map.put(config, :name, name))
  end

  defp build_config(opts) when is_list(opts) do
    defaults = default_config()
    merged = defaults |> Map.merge(Map.new(opts))

    merged
    |> Map.update!(:id, &to_string/1)
    |> Map.update!(:session_id, &to_string/1)
    |> Map.update!(:bot_username, &to_string/1)
    |> Map.update!(:bot_user_id, &to_int/1)
    |> Map.update!(:owner_user_id, &to_int/1)
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0
end
