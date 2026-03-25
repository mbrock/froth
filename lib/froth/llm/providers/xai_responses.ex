defmodule Froth.LLM.Providers.XAIResponses do
  @moduledoc """
  Provider for xAI Responses API (/v1/responses).
  Supports native x_search and web_search built-in tools.
  """

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Message, Request, Store}

  @impl true
  def build_request(%Request{} = request) do
    messages = encode_messages(request.messages, request.system)
    tools = encode_tools(request.tools)

    reasoning_effort = request.provider_options["reasoning_effort"]

    body =
      %{
        "model" => request.model,
        "input" => messages,
        "stream" => true
      }
      |> maybe_put("tools", tools)
      |> maybe_put("max_output_tokens", request.max_tokens)
      |> maybe_put("reasoning", reasoning_config(reasoning_effort))

    {:ok, %{url: request.endpoint, headers: request.headers, body: body}}
  end

  @impl true
  def decode_payload(%{"type" => "response.output_text.delta", "delta" => delta}, _store) do
    {[%Edit{op: :append, resource: ["message"], path: ["text"], value: delta}], false}
  end

  def decode_payload(%{"type" => "response.function_call_arguments.delta"} = p, store) do
    key = tool_call_key(p)
    delta = Map.get(p, "delta", "")
    id = tool_call_public_id(store, key, p)

    {[
       %Edit{
         op: :append,
         resource: ["message", "tool_calls", key],
         path: ["arguments_json"],
         value: delta,
         attrs: %{"id" => id}
       }
     ], false}
  end

  def decode_payload(%{"type" => "response.output_item.added", "item" => item}, _store) do
    case item do
      %{"type" => "function_call", "call_id" => id, "name" => name} ->
        key = tool_call_key(item)

        {[
           %Edit{
             op: :open,
             resource: ["message", "tool_calls", key],
             path: [],
             value: nil,
             attrs: %{"id" => id, "item_id" => Map.get(item, "id"), "name" => name}
           }
         ], false}

      _ ->
        {[], false}
    end
  end

  def decode_payload(%{"type" => "response.completed", "response" => resp}, _store) do
    usage = Map.get(resp, "usage", %{})

    edits = [
      %Edit{
        op: :merge,
        resource: ["message"],
        path: ["usage"],
        value: %{
          "prompt_tokens" => usage["input_tokens"] || 0,
          "completion_tokens" => usage["output_tokens"] || 0,
          "total_tokens" => (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
        }
      },
      %Edit{
        op: :set,
        resource: ["message"],
        path: ["stop_reason"],
        value: if(resp["status"] == "completed", do: "end_turn", else: resp["status"])
      }
    ]

    {edits, false}
  end

  def decode_payload(%{"type" => "response.output_text.done"}, _store), do: {[], false}
  def decode_payload(%{"type" => "response.content_part" <> _}, _store), do: {[], false}

  def decode_payload(
        %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item},
        _store
      ) do
    # Close the tool call when it's done
    key = tool_call_key(item)

    {[
       %Edit{
         op: :close,
         resource: ["message", "tool_calls", key],
         path: [],
         value: nil
       }
     ], false}
  end

  def decode_payload(_payload, _store), do: {[], false}

  @impl true
  def finalize(%Store{} = store) do
    text = Store.get(store, ["message", "text"], "")
    tool_calls = Store.get(store, ["message", "tool_calls"], %{})
    message = Store.get(store, ["message"], %{})

    content =
      []
      |> maybe_add_text_block(text)
      |> Kernel.++(tool_calls_to_content(tool_calls))

    %{
      text: text,
      content: content,
      stop_reason: Map.get(message, "stop_reason", "end_turn"),
      usage: Map.get(message, "usage", %{}),
      model: Map.get(message, "model"),
      message_id: Map.get(message, "id")
    }
  end

  @impl true
  def project_event(%Edit{op: :append, resource: ["message"], path: ["text"], value: text})
      when is_binary(text) do
    {:text_delta, text}
  end

  def project_event(%Edit{
        op: :open,
        resource: ["message", "tool_calls", _idx],
        attrs: %{"id" => id, "name" => name}
      }) do
    {:tool_use_start, %{"id" => id, "name" => name, "input" => %{}}}
  end

  def project_event(%Edit{
        op: :append,
        resource: ["message", "tool_calls", _idx],
        path: ["arguments_json"],
        value: json,
        attrs: %{"id" => id}
      }) do
    {:tool_use_delta, %{"id" => id, "partial_json" => json}}
  end

  def project_event(%Edit{op: :close, resource: ["message", "tool_calls", _idx]}), do: nil
  def project_event(_), do: nil

  # --- Helpers ---

  defp encode_messages(messages, system) do
    sys =
      if is_binary(system) and String.trim(system) != "" do
        [%{"role" => "system", "content" => String.trim(system)}]
      else
        []
      end

    sys ++ Enum.flat_map(messages, &encode_message/1)
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
    |> Enum.flat_map(fn
      %{"type" => "mcp_endpoint"} ->
        []

      # Built-in tools pass through
      %{"type" => type} when type in ["x_search", "web_search", "code_interpreter"] ->
        [%{"type" => type}]

      # Function tools get reformatted for Responses API
      tool ->
        [
          %{
            "type" => "function",
            "name" => tool["name"],
            "description" => tool["description"],
            "parameters" => tool["input_schema"]
          }
        ]
    end)
  end

  defp encode_tools(_), do: []

  defp reasoning_config(nil), do: nil
  defp reasoning_config(""), do: nil
  defp reasoning_config(effort) when is_binary(effort), do: %{"effort" => effort}
  defp reasoning_config(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_text_block(blocks, ""), do: blocks
  defp maybe_add_text_block(blocks, text), do: blocks ++ [%{"type" => "text", "text" => text}]

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

  defp tool_calls_to_content(tool_calls) when is_map(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.flat_map(fn {_idx, tc} ->
      input =
        case tc["arguments_json"] do
          json when is_binary(json) ->
            case Jason.decode(json) do
              {:ok, parsed} -> parsed
              _ -> %{}
            end

          _ ->
            %{}
        end

      case {tc["id"], tc["name"]} do
        {id, name} when is_binary(id) and id != "" and is_binary(name) and name != "" ->
          [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]

        _ ->
          []
      end
    end)
  end

  defp tool_calls_to_content(_), do: []

  defp tool_call_key(%{"item_id" => item_id}) when is_binary(item_id) and item_id != "",
    do: item_id

  defp tool_call_key(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp tool_call_key(%{"index" => idx}) when is_integer(idx), do: idx
  defp tool_call_key(%{"output_index" => idx}) when is_integer(idx), do: idx
  defp tool_call_key(_payload), do: 0

  defp tool_call_public_id(%Store{} = store, key, payload) do
    case Store.get(store, ["message", "tool_calls", key], %{}) do
      %{"id" => id} when is_binary(id) and id != "" ->
        id

      _ ->
        Map.get(payload, "call_id") || Map.get(payload, "item_id") || ""
    end
  end

  defp encode_role(:system), do: "system"
  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "assistant"
end
