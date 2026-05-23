defmodule Froth.Telegram.Charlie do
  @moduledoc """
  Charlie bot profile (identity + prompt config) backed by `Froth.Telegram.Bot`.
  """

  alias Froth.Telegram.BotRuntime
  alias Froth.Telegram.Profiles.CharliePrompt
  alias Froth.Telegram.Toolsets.Charlie, as: CharlieTools

  @default_bot_id "charlie"
  @default_bot_username "charliebuddybot"
  @default_session_id "charlie"
  @default_model "claude-opus-4-6"
  @default_max_tokens 65_536

  def default_config do
    cfg = Application.get_env(:froth, __MODULE__, [])

    %{
      runtime_module: __MODULE__,
      id: @default_bot_id,
      bot_username: @default_bot_username,
      bot_user_id: Keyword.get(cfg, :bot_user_id, 0),
      owner_user_id: Keyword.get(cfg, :owner_user_id, 0),
      session_id: @default_session_id,
      model: @default_model,
      max_tokens: @default_max_tokens,
      failure_report_model: "gpt-5.4",
      system_prompt_fun: &CharliePrompt.system_prompt/2,
      name_triggers: [
        "charlie",
        "charkie",
        "tartlie",
        "calling all robots",
        "calling all the robots",
        "calling on all robots",
        "calling on all the robots",
        "calling on the robots"
      ],
      tools_module: CharlieTools,
      chronicle_dir: Application.app_dir(:froth, "priv/chronicle"),
      # recent_window_target_hours: 4,
      # recent_window_min_hours: 1,
      # recent_window_backfill_hours: 8,
      # recent_window_char_budget: 200_000,
      # recent_window_bucket_minutes: 30,
      recent_message_limit: 500,
      recent_message_anchor_size: 100,
      debounce_ms: 2000
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
    name = Keyword.get(opts, :name, __MODULE__)

    config =
      default_config()
      |> Map.merge(Map.new(opts))
      |> Map.put(:name, name)

    BotRuntime.start_link(config)
  end
end
