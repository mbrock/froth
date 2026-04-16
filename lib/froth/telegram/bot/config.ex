defmodule Froth.Telegram.Bot.Config do
  @moduledoc """
  Static configuration for a `Froth.Telegram.Bot` instance.

  Required fields are enforced at struct construction. There are no
  application-wide defaults for things like `:model` or
  `:system_prompt_fun` — every caller must spell those out explicitly,
  via a profile module like `Froth.Telegram.Charlie`.
  """

  @enforce_keys [
    :id,
    :session_id,
    :bot_username,
    :bot_user_id,
    :owner_user_id,
    :model
  ]

  defstruct [
    :id,
    :session_id,
    :bot_username,
    :bot_user_id,
    :owner_user_id,
    :model,
    :tools_module,
    :tools,
    :system_prompt,
    :system_prompt_fun,
    :thinking,
    :effort,
    :chronicle_dir,
    :recent_message_limit,
    :recent_message_anchor_size,
    name_triggers: [],
    debounce_ms: 0
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          bot_username: String.t(),
          bot_user_id: integer(),
          owner_user_id: integer(),
          model: String.t(),
          system_prompt_fun: function(),
          tools_module: module(),
          tools: [map()] | nil,
          system_prompt: String.t() | nil,
          thinking: map() | nil,
          effort: String.t() | nil,
          chronicle_dir: String.t() | nil,
          recent_message_limit: pos_integer() | nil,
          recent_message_anchor_size: pos_integer() | nil,
          name_triggers: [String.t()],
          debounce_ms: non_neg_integer()
        }

  @doc """
  Build a `Bot.Config` from a keyword list or map.

  Ignores keys that are not `Bot.Config` fields (for example
  `:runtime_module` or `:name`). Coerces `id`, `session_id`, and
  `bot_username` to strings and `bot_user_id`, `owner_user_id` to
  integers. Raises if any `@enforce_keys` field is missing.
  """
  @spec build(keyword() | map()) :: t()
  def build(opts) when is_list(opts), do: build(Map.new(opts))

  def build(opts) when is_map(opts) do
    known_keys = __struct__() |> Map.from_struct() |> Map.keys()

    config =
      opts
      |> Map.take(known_keys)
      |> Map.update!(:id, &to_string/1)
      |> Map.update!(:session_id, &to_string/1)
      |> Map.update!(:bot_username, &to_string/1)
      |> Map.update(:bot_user_id, 0, &coerce_int/1)
      |> Map.update(:owner_user_id, 0, &coerce_int/1)
      |> then(&struct!(__MODULE__, &1))

    validate_prompt_source!(config)
    validate_tool_source!(config)
    config
  end

  defp validate_prompt_source!(%__MODULE__{system_prompt: nil, system_prompt_fun: nil}) do
    raise ArgumentError,
          "Bot.Config requires either :system_prompt (binary) or :system_prompt_fun (function)"
  end

  defp validate_prompt_source!(_config), do: :ok

  defp validate_tool_source!(%__MODULE__{tools: nil, tools_module: nil}) do
    raise ArgumentError,
          "Bot.Config requires either :tools (a list) or :tools_module (a module)"
  end

  defp validate_tool_source!(_config), do: :ok

  defp coerce_int(value) when is_integer(value), do: value

  defp coerce_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp coerce_int(_value), do: 0
end
