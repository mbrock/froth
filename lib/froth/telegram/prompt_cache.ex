defmodule Froth.Telegram.PromptCache do
  @moduledoc false

  alias Froth.LLM

  @default_cache_control %{"type" => "ephemeral", "ttl" => "1h"}
  @tail_breakpoint_backoff 3

  def text_blocks(parts, bot_config)
      when is_list(parts) and is_map(bot_config) do
    breakpoint_indices = breakpoint_indices(parts, bot_config)

    parts
    |> Enum.with_index()
    |> Enum.map(fn {part, idx} ->
      block = %{"type" => "text", "text" => part}

      if idx in breakpoint_indices do
        Map.put(block, "cache_control", @default_cache_control)
      else
        block
      end
    end)
  end

  def text_blocks(parts, _bot_config) when is_list(parts) do
    Enum.map(parts, fn part -> %{"type" => "text", "text" => part} end)
  end

  defp breakpoint_indices(parts, bot_config) do
    if anthropic_model?(bot_config) do
      chapter_idx =
        parts
        |> Enum.with_index()
        |> Enum.filter(fn {part, _idx} ->
          is_binary(part) and String.starts_with?(part, "<chapter ")
        end)
        |> List.last()
        |> case do
          {_part, idx} -> idx
          nil -> nil
        end

      final_idx =
        case parts do
          [] -> nil
          _ -> max(length(parts) - 1 - @tail_breakpoint_backoff, 0)
        end

      [chapter_idx, final_idx]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    else
      []
    end
  end

  defp anthropic_model?(%{model: model}) when is_binary(model) do
    LLM.resolve_provider_name(nil, model) == :anthropic
  end

  defp anthropic_model?(_bot_config), do: false
end
