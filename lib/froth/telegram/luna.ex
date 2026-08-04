defmodule Froth.Telegram.Luna do
  @moduledoc """
  Luna bot profile: an independent GPT-5.6 identity sharing Froth's
  chronicle, tools, and generic Telegram runtime with Charlie.
  """

  alias Froth.Telegram.BotRuntime
  alias Froth.Telegram.Profiles.LunaPrompt
  alias Froth.Telegram.Toolsets.Charlie, as: CharlieTools

  @default_bot_id "luna"
  @default_bot_username "barblebot"
  @default_session_id "agentbot"
  @default_model "gpt-5.6-luna"
  @default_max_tokens 65_536

  def default_config do
    cfg = Application.get_env(:froth, __MODULE__, [])

    %{
      runtime_module: __MODULE__,
      id: @default_bot_id,
      bot_username: Keyword.get(cfg, :bot_username, @default_bot_username),
      bot_user_id: Keyword.get(cfg, :bot_user_id, 0),
      owner_user_id: Keyword.get(cfg, :owner_user_id, 0),
      session_id: Keyword.get(cfg, :session_id, @default_session_id),
      model: @default_model,
      max_tokens: @default_max_tokens,
      system_prompt_fun: &LunaPrompt.system_prompt/2,
      name_triggers: ["luna", "lulu"],
      tools_module: CharlieTools,
      chronicle_dir: Application.app_dir(:froth, "priv/chronicle"),
      daily_summary_limit: 7,
      recent_message_limit: 500,
      recent_message_anchor_size: 100,
      debounce_ms: 2000
    }
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:id] || opts["id"] || @default_bot_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts \\ [])

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    config =
      default_config()
      |> Map.merge(Map.new(opts))
      |> Map.put(:name, name)

    BotRuntime.start_link(config)
  end
end
