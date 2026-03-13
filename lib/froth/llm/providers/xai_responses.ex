defmodule Froth.LLM.Providers.XAIResponses do
  @moduledoc """
  Provider for xAI Responses API (/v1/responses).
  Supports native x_search and web_search built-in tools.
  """

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Request, Store}

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

    msgs =
      Enum.map(messages, fn
        %{"role" => "tool", "tool_use_id" => id, "content" => content} ->
          %{"type" => "function_call_output", "call_id" => id, "output" => to_string(content)}

        %{"role" => role, "content" => content} when is_binary(content) ->
          %{"role" => role, "content" => content}

        %{"role" => role, "content" => content} when is_list(content) ->
          text =
            content
            |> Enum.filter(&match?(%{"type" => "text"}, &1))
            |> Enum.map(& &1["text"])
            |> Enum.join("\n")

          tool_calls =
            content
            |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
            |> Enum.map(fn tc ->
              %{
                "type" => "function_call",
                "call_id" => tc["id"],
                "name" => tc["name"],
                "arguments" => Jason.encode!(tc["input"] || %{})
              }
            end)

          items = if text != "", do: [%{"role" => role, "content" => text}], else: []
          items ++ tool_calls

        msg ->
          msg
      end)
      |> List.flatten()

    sys ++ msgs
  end

  defp encode_tools(tools) when is_list(tools) do
    tools
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      # Built-in tools pass through
      %{"type" => type} when type in ["x_search", "web_search", "code_interpreter"] ->
        %{"type" => type}

      # Function tools get reformatted for Responses API
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

  defp reasoning_config(nil), do: nil
  defp reasoning_config(""), do: nil
  defp reasoning_config(effort) when is_binary(effort), do: %{"effort" => effort}
  defp reasoning_config(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_text_block(blocks, ""), do: blocks
  defp maybe_add_text_block(blocks, text), do: blocks ++ [%{"type" => "text", "text" => text}]

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
end
