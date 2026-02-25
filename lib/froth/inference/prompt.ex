defmodule Froth.Inference.Prompt do
  @moduledoc false

  @prompt_cache_control %{"type" => "ephemeral", "ttl" => "1h"}

  @spec initial_user_content(String.t() | [String.t()], String.t(), String.t()) ::
          String.t() | [map()]
  def initial_user_content(context_blocks, eval_hint, new_messages_section)
      when is_list(context_blocks) and is_binary(eval_hint) and is_binary(new_messages_section) do
    context_blocks =
      context_blocks
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(String.trim(&1) == ""))

    if context_blocks == [] do
      full_user_prompt("", eval_hint, new_messages_section)
    else
      last_index = length(context_blocks) - 1

      context_blocks =
        Enum.with_index(context_blocks)
        |> Enum.map(fn {block, idx} ->
          if idx == last_index do
            cached_text_block(block)
          else
            %{"type" => "text", "text" => block}
          end
        end)

      context_blocks ++
        [%{"type" => "text", "text" => dynamic_suffix(eval_hint, new_messages_section)}]
    end
  end

  def initial_user_content(context, eval_hint, new_messages_section)
      when is_binary(context) and is_binary(eval_hint) and is_binary(new_messages_section) do
    user_prompt = full_user_prompt(context, eval_hint, new_messages_section)

    if String.trim(context) == "" do
      user_prompt
    else
      {prefix, suffix} = String.split_at(user_prompt, String.length(context))

      if prefix == context do
        [cached_text_block(context), %{"type" => "text", "text" => suffix}]
      else
        user_prompt
      end
    end
  end

  @spec full_user_prompt(String.t(), String.t(), String.t()) :: String.t()
  def full_user_prompt(context, eval_hint, new_messages_section)
      when is_binary(context) and is_binary(eval_hint) and is_binary(new_messages_section) do
    """
    #{context}
    #{eval_hint}

    <new_messages>
    #{new_messages_section}
    </new_messages>

    Respond to these messages. Use the send_message tool.
    """
  end

  defp dynamic_suffix(eval_hint, new_messages_section)
       when is_binary(eval_hint) and is_binary(new_messages_section) do
    full_user_prompt("", eval_hint, new_messages_section)
  end

  defp cached_text_block(text) when is_binary(text) do
    %{
      "type" => "text",
      "text" => text,
      "cache_control" => @prompt_cache_control
    }
  end
end
