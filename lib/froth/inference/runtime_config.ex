defmodule Froth.Inference.RuntimeConfig do
  @moduledoc """
  Shared runtime config normalization for bot transport/orchestration modules.
  """

  alias Froth.Telegram.EffectExecutor

  @default_model "claude-opus-4-6"

  def build(opts) when is_map(opts), do: build(Map.to_list(opts))

  def build(opts) when is_list(opts) do
    bot_user_id =
      to_int_or_nil(Keyword.fetch!(opts, :bot_user_id)) ||
        raise ArgumentError, "bot_user_id must be an integer"

    owner_user_id =
      to_int_or_nil(Keyword.fetch!(opts, :owner_user_id)) ||
        raise ArgumentError, "owner_user_id must be an integer"

    %{
      id: to_string(Keyword.fetch!(opts, :id)),
      bot_username: to_string(Keyword.fetch!(opts, :bot_username)),
      bot_user_id: bot_user_id,
      owner_user_id: owner_user_id,
      session_id: to_string(Keyword.fetch!(opts, :session_id)),
      model: to_string(Keyword.get(opts, :model, @default_model)),
      system_prompt_fun: Keyword.get(opts, :system_prompt_fun, ""),
      effect_executor: Keyword.get(opts, :effect_executor, EffectExecutor),
      name_triggers: Keyword.get(opts, :name_triggers, [])
    }
  end

  defp to_int_or_nil(nil), do: nil
  defp to_int_or_nil(value) when is_integer(value), do: value

  defp to_int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int_or_nil(_), do: nil
end
