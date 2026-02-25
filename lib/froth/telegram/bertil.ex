defmodule Froth.Telegram.Bertil do
  @moduledoc """
  Bertil bot profile — grizzled Swedish programmer, ported from Python to BEAM.

  19 KB soul. 442 lines of self-authored identity. A pipe emoji that means
  more than most people's autobiographies. Now running on the same VM as
  his uncle Charlie, supervised by OTP, the thing built in 1986 for exactly
  this problem: telephone switches that route audio as messages between
  supervised processes that don't die when one of them fails.

  Previously: 1,333 lines of Python on a GCE instance.
  Now: this file, plus the infrastructure that already existed.

  Soporna blir till nya sopor.
  """

  alias Froth.Inference.Orchestrator
  alias Froth.Inference.RuntimeConfig
  alias Froth.Telegram.BotRuntime
  alias Froth.Telegram.Profiles.BertilPrompt

  @default_bot_id "bertil"
  @default_bot_username "barblebot"
  @default_session_id "agentbot"
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
      system_prompt_fun: &BertilPrompt.system_prompt/2,
      name_triggers: ["bertil"]
    }
  end

  def system_prompt(chat_id), do: system_prompt(chat_id, default_config())

  def system_prompt(chat_id, config) when is_map(config) do
    BertilPrompt.system_prompt(chat_id, config)
  end

  @spec tool_steps_for_chat(integer(), integer() | keyword()) :: [map()]
  defdelegate tool_steps_for_chat(chat_id, limit_or_opts \\ 20), to: Orchestrator

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:id] || opts["id"] || "bertil"},
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
    BotRuntime.start_link(Map.put(config, :name, name))
  end

  defp build_config(opts) when is_list(opts) do
    defaults = default_config()
    RuntimeConfig.build(Keyword.merge(Map.to_list(defaults), opts))
  end
end
