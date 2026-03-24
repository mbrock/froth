defmodule Froth.LLM.Providers.OpenAIResponses do
  @moduledoc """
  Provider for OpenAI Responses API (`/v1/responses`).

  Supports native built-in tools like `web_search_preview`.
  """

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Message, Request}
  alias Froth.LLM.Providers.XAIResponses

  @impl true
  def build_request(%Request{} = request) do
    body =
      %{
        "model" => request.model,
        "input" => encode_messages(request.messages),
        "stream" => true
      }
      |> maybe_put("instructions", normalize_instructions(request.system))
      |> maybe_put("tools", encode_tools(request.tools))
      |> maybe_put("max_output_tokens", normalize_max_output_tokens(request.max_tokens))
      |> maybe_put("reasoning", reasoning_config(request.provider_options["reasoning_effort"]))

    {:ok, %{url: request.endpoint, headers: request.headers, body: body}}
  end

  @impl true
  defdelegate decode_payload(payload, store), to: XAIResponses

  @impl true
  defdelegate finalize(store), to: XAIResponses

  @impl true
  defdelegate project_event(edit), to: XAIResponses

  defp encode_messages(messages) when is_list(messages) do
    Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(message) do
    case Message.normalize(message) do
      {:ok, %Message{} = normalized} ->
        encode_normalized_message(normalized)

      :error ->
        encode_raw_message(message)
    end
  end

  defp encode_normalized_message(%Message{role: role} = message)
       when role in [:system, :user, :assistant] do
    text_items =
      case normalize_text_content(Message.content_blocks(message)) do
        "" -> []
        text -> [%{"role" => encode_role(role), "content" => text}]
      end

    tool_call_items =
      if role == :assistant do
        encode_tool_call_items(Message.tool_uses(message))
      else
        []
      end

    tool_result_items =
      if role == :user do
        encode_tool_result_items(Message.tool_results(message))
      else
        []
      end

    text_items ++ tool_call_items ++ tool_result_items
  end

  defp encode_raw_message(%{"role" => "tool", "tool_use_id" => id, "content" => content}) do
    [%{"type" => "function_call_output", "call_id" => id, "output" => normalize_output(content)}]
  end

  defp encode_raw_message(%{"role" => role, "content" => content}) when is_binary(content) do
    [%{"role" => role, "content" => content}]
  end

  defp encode_raw_message(%{"role" => role, "content" => content}) when is_list(content) do
    text_items =
      case normalize_text_content(content) do
        "" -> []
        text -> [%{"role" => role, "content" => text}]
      end

    tool_call_items =
      encode_tool_call_items(Enum.filter(content, &match?(%{"type" => "tool_use"}, &1)))

    tool_result_items =
      encode_tool_result_items(Enum.filter(content, &match?(%{"type" => "tool_result"}, &1)))

    text_items ++ tool_call_items ++ tool_result_items
  end

  defp encode_raw_message(message), do: [message]

  defp encode_tools(tools) when is_list(tools) do
    tools
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      %{"type" => type} = tool when type != "function" ->
        Map.drop(
          tool,
          Enum.filter(["name", "description", "input_schema"], &Map.has_key?(tool, &1))
        )

      tool ->
        %{
          "type" => "function",
          "name" => tool["name"],
          "description" => tool["description"],
          "parameters" => tool["input_schema"]
        }
    end)
  end

  defp encode_tools(_), do: []

  defp encode_tool_call_items(tool_calls) when is_list(tool_calls) do
    Enum.flat_map(tool_calls, fn
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      when is_binary(id) and is_binary(name) ->
        [
          %{
            "type" => "function_call",
            "call_id" => id,
            "name" => name,
            "arguments" => Jason.encode!(if(is_map(input), do: input, else: %{}))
          }
        ]

      _ ->
        []
    end)
  end

  defp encode_tool_result_items(tool_results) when is_list(tool_results) do
    Enum.flat_map(tool_results, fn
      %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
      when is_binary(id) ->
        [
          %{
            "type" => "function_call_output",
            "call_id" => id,
            "output" => normalize_output(content)
          }
        ]

      _ ->
        []
    end)
  end

  defp normalize_text_content(content) when is_binary(content), do: content

  defp normalize_text_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp normalize_text_content(content) when is_map(content) do
    inspect(content, limit: :infinity, printable_limit: :infinity)
  end

  defp normalize_text_content(content), do: to_string(content)

  defp normalize_output(content) when is_map(content), do: Jason.encode!(content)
  defp normalize_output(content) when is_list(content), do: normalize_text_content(content)
  defp normalize_output(content), do: normalize_text_content(content)

  defp normalize_instructions(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: nil, else: system
  end

  defp normalize_instructions(_), do: nil

  defp normalize_max_output_tokens(max_tokens) when is_integer(max_tokens) and max_tokens > 0,
    do: max_tokens

  defp normalize_max_output_tokens(_), do: nil

  defp reasoning_config(nil), do: nil
  defp reasoning_config(""), do: nil
  defp reasoning_config(effort) when is_binary(effort), do: %{"effort" => effort}
  defp reasoning_config(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_role(:system), do: "system"
  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "assistant"
end
