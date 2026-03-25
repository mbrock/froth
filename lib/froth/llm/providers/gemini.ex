defmodule Froth.LLM.Providers.Gemini do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Message, Request, Store}

  @impl true
  def build_request(%Request{} = request) do
    body =
      %{
        "contents" => encode_messages(request.messages)
      }
      |> maybe_put("systemInstruction", system_instruction(request.system), &is_map/1)
      |> maybe_put("tools", encode_tools(request.tools), &non_empty_list?/1)
      |> maybe_put("generationConfig", generation_config(request), &non_empty_map?/1)

    {:ok, %{url: request.endpoint, headers: request.headers, body: body}}
  end

  @impl true
  def decode_payload(%{"promptFeedback" => %{"blockReason" => reason}} = payload, _store)
      when is_binary(reason) do
    edits =
      []
      |> maybe_add_set(["message"], ["id"], payload["responseId"], payload)
      |> maybe_add_set(["message"], ["model"], payload["modelVersion"], payload)
      |> maybe_add_merge(
        ["message"],
        ["usage"],
        normalize_usage(payload["usageMetadata"]),
        payload
      )
      |> Kernel.++([
        %Edit{
          op: :set,
          resource: ["message"],
          path: ["stop_reason"],
          value: normalize_finish_reason(reason),
          raw: payload
        }
      ])

    {edits, true}
  end

  def decode_payload(%{} = payload, %Store{} = store) do
    candidate = first_candidate(payload)
    finish_reason = candidate && candidate["finishReason"]

    edits =
      []
      |> maybe_add_set(["message"], ["id"], payload["responseId"], payload)
      |> maybe_add_set(["message"], ["model"], payload["modelVersion"], payload)
      |> maybe_add_merge(
        ["message"],
        ["usage"],
        normalize_usage(payload["usageMetadata"]),
        payload
      )
      |> maybe_add_parts(candidate, store, payload)
      |> maybe_add_finish_reason(finish_reason, payload)

    {edits, false}
  end

  @impl true
  def finalize(%Store{} = store) do
    message = Store.get(store, ["message"], %{})
    blocks = Map.get(message, "blocks", %{})
    content = blocks_to_content(blocks)

    %{
      text: blocks_text(content),
      content: content,
      stop_reason: Map.get(message, "stop_reason"),
      usage: Map.get(message, "usage", %{}),
      model: Map.get(message, "model"),
      message_id: Map.get(message, "id")
    }
  end

  @impl true
  def project_event(%Edit{
        op: :append,
        resource: ["message", "blocks", _idx],
        path: ["text"],
        value: text
      })
      when is_binary(text) do
    {:text_delta, text}
  end

  def project_event(%Edit{
        op: :open,
        resource: ["message", "blocks", _idx],
        attrs: %{"type" => "tool_use", "id" => id, "name" => name} = attrs
      })
      when is_binary(id) and is_binary(name) do
    {:tool_use_start, %{"id" => id, "name" => name, "input" => Map.get(attrs, "input", %{})}}
  end

  def project_event(%Edit{
        op: :close,
        resource: ["message", "blocks", _idx],
        attrs: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      })
      when is_binary(id) and is_binary(name) do
    {:tool_use_stop, %{"id" => id, "name" => name, "input" => input}}
  end

  def project_event(%Edit{op: :merge, resource: ["message"], path: ["usage"], value: usage})
      when is_map(usage) do
    {:usage, %{"usage" => usage}}
  end

  def project_event(_edit), do: nil

  def encode_messages(messages) when is_list(messages) do
    {contents, _tool_uses} =
      Enum.reduce(messages, {[], %{}}, fn message, {contents, tool_uses} ->
        {encoded, tool_uses} = encode_message(message, tool_uses)
        {contents ++ encoded, tool_uses}
      end)

    contents
  end

  defp encode_message(message, tool_uses) do
    case Message.normalize(message) do
      {:ok, %Message{} = normalized} -> encode_normalized_message(normalized, tool_uses)
      :error -> encode_raw_message(message, tool_uses)
    end
  end

  defp encode_normalized_message(%Message{role: :system}, tool_uses), do: {[], tool_uses}

  defp encode_normalized_message(%Message{role: :user} = message, tool_uses) do
    {parts, tool_uses} = encode_user_parts(Message.content_blocks(message), tool_uses)

    if parts == [] do
      {[], tool_uses}
    else
      {[%{"role" => "user", "parts" => parts}], tool_uses}
    end
  end

  defp encode_normalized_message(%Message{role: :assistant} = message, tool_uses) do
    {parts, tool_uses} = encode_model_parts(Message.content_blocks(message), tool_uses)

    if parts == [] do
      {[], tool_uses}
    else
      {[%{"role" => "model", "parts" => parts}], tool_uses}
    end
  end

  defp encode_raw_message(%{"role" => "system"}, tool_uses), do: {[], tool_uses}

  defp encode_raw_message(%{"role" => role, "parts" => parts} = message, tool_uses)
       when role in ["user", "model"] and is_list(parts) do
    {parts, tool_uses} = normalize_gemini_parts(parts, tool_uses)
    {[Map.put(message, "parts", parts)], tool_uses}
  end

  defp encode_raw_message(%{"role" => "user", "content" => content}, tool_uses) do
    {parts, tool_uses} = encode_user_parts(content, tool_uses)

    if parts == [] do
      {[], tool_uses}
    else
      {[%{"role" => "user", "parts" => parts}], tool_uses}
    end
  end

  defp encode_raw_message(%{"role" => "assistant", "content" => content}, tool_uses) do
    {parts, tool_uses} = encode_model_parts(content, tool_uses)

    if parts == [] do
      {[], tool_uses}
    else
      {[%{"role" => "model", "parts" => parts}], tool_uses}
    end
  end

  defp encode_raw_message(message, tool_uses) when is_map(message) do
    {[message], tool_uses}
  end

  defp encode_raw_message(_message, tool_uses), do: {[], tool_uses}

  defp encode_user_parts(content, tool_uses) when is_binary(content) do
    {[%{"text" => content}], tool_uses}
  end

  defp encode_user_parts(content, tool_uses) when is_list(content) do
    Enum.reduce(content, {[], tool_uses}, fn block, {parts, current_tool_uses} ->
      {part, next_tool_uses} = encode_user_part(block, current_tool_uses)

      if is_nil(part) do
        {parts, next_tool_uses}
      else
        {parts ++ [part], next_tool_uses}
      end
    end)
  end

  defp encode_user_parts(content, tool_uses) do
    {[%{"text" => normalize_text_content(content)}], tool_uses}
  end

  defp encode_user_part(
         %{"type" => "tool_result", "tool_use_id" => tool_use_id} = block,
         tool_uses
       )
       when is_binary(tool_use_id) do
    tool_use = Map.get(tool_uses, tool_use_id, %{})
    name = block["name"] || tool_use["name"]

    part =
      if is_binary(name) and String.trim(name) != "" do
        %{
          "functionResponse" => %{
            "name" => name,
            "id" => tool_use_id,
            "response" => function_response_payload(block)
          }
        }
      end

    {part, tool_uses}
  end

  defp encode_user_part(%{"text" => text}, tool_uses) when is_binary(text) do
    {%{"text" => text}, tool_uses}
  end

  defp encode_user_part(%{"text" => _} = part, tool_uses), do: {part, tool_uses}

  defp encode_user_part(%{"functionResponse" => _} = part, tool_uses), do: {part, tool_uses}
  defp encode_user_part(%{"inlineData" => _} = part, tool_uses), do: {part, tool_uses}
  defp encode_user_part(%{"fileData" => _} = part, tool_uses), do: {part, tool_uses}

  defp encode_user_part(other, tool_uses) do
    {%{"text" => normalize_text_content(other)}, tool_uses}
  end

  defp encode_model_parts(content, tool_uses) when is_binary(content) do
    {[%{"text" => content}], tool_uses}
  end

  defp encode_model_parts(content, tool_uses) when is_list(content) do
    Enum.reduce(content, {[], tool_uses}, fn block, {parts, current_tool_uses} ->
      {part, next_tool_uses} = encode_model_part(block, current_tool_uses)

      if is_nil(part) do
        {parts, next_tool_uses}
      else
        {parts ++ [part], next_tool_uses}
      end
    end)
  end

  defp encode_model_parts(content, tool_uses) do
    {[%{"text" => normalize_text_content(content)}], tool_uses}
  end

  defp encode_model_part(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block,
         tool_uses
       )
       when is_binary(id) and is_binary(name) and is_map(input) do
    part =
      %{
        "functionCall" => %{
          "id" => id,
          "name" => name,
          "args" => input
        }
      }
      |> maybe_put_thought_signature(block)

    tool_use = %{"id" => id, "name" => name, "input" => input}
    {part, Map.put(tool_uses, id, tool_use)}
  end

  defp encode_model_part(%{"text" => text}, tool_uses) when is_binary(text) do
    {%{"text" => text}, tool_uses}
  end

  defp encode_model_part(
         %{"functionCall" => %{"id" => id, "name" => name} = function_call} = part,
         tool_uses
       )
       when is_binary(id) and is_binary(name) do
    args = function_call["args"]
    tool_use = %{"id" => id, "name" => name, "input" => if(is_map(args), do: args, else: %{})}
    {part, Map.put(tool_uses, id, tool_use)}
  end

  defp encode_model_part(%{"functionCall" => _} = part, tool_uses), do: {part, tool_uses}
  defp encode_model_part(%{"inlineData" => _} = part, tool_uses), do: {part, tool_uses}
  defp encode_model_part(%{"fileData" => _} = part, tool_uses), do: {part, tool_uses}

  defp encode_model_part(other, tool_uses) do
    {%{"text" => normalize_text_content(other)}, tool_uses}
  end

  defp normalize_gemini_parts(parts, tool_uses) do
    Enum.reduce(parts, {[], tool_uses}, fn part, {acc, current_tool_uses} ->
      {normalized_part, next_tool_uses} =
        cond do
          Map.has_key?(part, "functionCall") ->
            encode_model_part(part, current_tool_uses)

          true ->
            {part, current_tool_uses}
        end

      {acc ++ [normalized_part], next_tool_uses}
    end)
  end

  defp encode_tools([]), do: []

  defp encode_tools(tools) when is_list(tools) do
    {declarations, builtins} =
      Enum.reduce(tools, {[], []}, fn tool, {declarations, builtins} ->
        case encode_tool(tool) do
          {:function, declaration} -> {declarations ++ [declaration], builtins}
          {:builtin, builtin} -> {declarations, builtins ++ [builtin]}
          :skip -> {declarations, builtins}
        end
      end)

    []
    |> maybe_add_function_declarations(declarations)
    |> Kernel.++(builtins)
  end

  defp encode_tools(_tools), do: []

  defp encode_tool(%{"type" => "web_search"}), do: {:builtin, %{"googleSearch" => %{}}}
  defp encode_tool(%{"type" => "google_search"}), do: {:builtin, %{"googleSearch" => %{}}}

  defp encode_tool(%{"type" => "google_search_retrieval"} = tool),
    do: {:builtin, google_search_retrieval_tool(tool)}

  defp encode_tool(%{"googleSearch" => _} = tool), do: {:builtin, tool}
  defp encode_tool(%{"google_search" => _}), do: {:builtin, %{"googleSearch" => %{}}}
  defp encode_tool(%{"googleSearchRetrieval" => _} = tool), do: {:builtin, tool}
  defp encode_tool(%{"google_search_retrieval" => _} = tool), do: {:builtin, tool}
  defp encode_tool(%{"codeExecution" => _} = tool), do: {:builtin, tool}
  defp encode_tool(%{"type" => "mcp_endpoint"}), do: :skip

  defp encode_tool(tool) when is_map(tool) do
    {:function,
     %{
       "name" => tool["name"],
       "description" => tool["description"],
       "parameters" => tool["input_schema"]
     }}
  end

  defp encode_tool(_tool), do: :skip

  defp google_search_retrieval_tool(%{"google_search_retrieval" => _} = tool), do: tool

  defp google_search_retrieval_tool(%{"googleSearchRetrieval" => _} = tool), do: tool

  defp google_search_retrieval_tool(tool) when is_map(tool) do
    config =
      tool
      |> Map.drop(["type"])
      |> case do
        %{} = config when map_size(config) > 0 -> config
        _ -> %{}
      end

    %{"google_search_retrieval" => config}
  end

  defp maybe_add_function_declarations(tools, []), do: tools

  defp maybe_add_function_declarations(tools, declarations) do
    tools ++ [%{"functionDeclarations" => declarations}]
  end

  defp system_instruction(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: nil, else: %{"parts" => [%{"text" => system}]}
  end

  defp system_instruction(_system), do: nil

  defp generation_config(%Request{} = request) do
    %{}
    |> maybe_put("maxOutputTokens", request.max_tokens, &positive_integer?/1)
  end

  defp maybe_add_parts(edits, %{"content" => %{"parts" => parts}}, %Store{} = store, payload)
       when is_list(parts) do
    Enum.with_index(parts)
    |> Enum.reduce(edits, fn {part, idx}, acc ->
      block_path = ["message", "blocks", idx]
      current_block = Store.get(store, block_path, %{})

      cond do
        is_binary(part["text"]) and part["text"] != "" ->
          acc
          |> maybe_open_text_block(block_path, current_block, payload)
          |> Kernel.++([
            %Edit{
              op: :append,
              resource: block_path,
              path: ["text"],
              value: part["text"],
              raw: payload
            }
          ])

        is_map(part["functionCall"]) ->
          acc ++ function_call_edits(block_path, part, payload)

        true ->
          acc
      end
    end)
  end

  defp maybe_add_parts(edits, _candidate, _store, _payload), do: edits

  defp maybe_open_text_block(edits, block_path, current_block, payload) do
    if current_block["type"] == "text" do
      edits
    else
      edits ++
        [
          %Edit{
            op: :open,
            resource: block_path,
            attrs: %{"type" => "text", "text" => ""},
            raw: payload
          }
        ]
    end
  end

  defp function_call_edits(block_path, part, payload) do
    function_call = part["functionCall"]
    id = function_call["id"]
    name = function_call["name"]
    input = if is_map(function_call["args"]), do: function_call["args"], else: %{}

    attrs =
      %{
        "type" => "tool_use",
        "id" => id,
        "name" => name,
        "input" => input
      }
      |> maybe_put_extra_content(part)

    [
      %Edit{op: :open, resource: block_path, attrs: attrs, raw: payload},
      %Edit{op: :close, resource: block_path, attrs: attrs, raw: payload}
    ]
  end

  defp maybe_put_extra_content(attrs, %{"thoughtSignature" => signature})
       when is_binary(signature) do
    Map.put(attrs, "extra_content", %{"google" => %{"thought_signature" => signature}})
  end

  defp maybe_put_extra_content(attrs, _part), do: attrs

  defp maybe_put_thought_signature(part, %{
         "extra_content" => %{"google" => %{"thought_signature" => signature}}
       })
       when is_binary(signature) do
    Map.put(part, "thoughtSignature", signature)
  end

  defp maybe_put_thought_signature(part, _block), do: part

  defp function_response_payload(%{"content" => content, "is_error" => true}) do
    %{"error" => normalize_tool_response_content(content)}
  end

  defp function_response_payload(%{"content" => content}) do
    %{"result" => normalize_tool_response_content(content)}
  end

  defp normalize_tool_response_content(content) when is_map(content), do: content

  defp normalize_tool_response_content(content) when is_list(content),
    do: normalize_text_content(content)

  defp normalize_tool_response_content(content), do: normalize_text_content(content)

  defp normalize_text_content(content) when is_binary(content), do: content

  defp normalize_text_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp normalize_text_content(content) when is_map(content) do
    inspect(content, limit: :infinity, printable_limit: :infinity)
  end

  defp normalize_text_content(content), do: to_string(content)

  defp first_candidate(%{"candidates" => [candidate | _]}) when is_map(candidate), do: candidate
  defp first_candidate(_payload), do: nil

  defp normalize_usage(%{"promptTokenCount" => _} = usage) do
    %{
      "input_tokens" => usage["promptTokenCount"] || 0,
      "output_tokens" => usage["candidatesTokenCount"] || 0,
      "cache_read_input_tokens" => usage["cachedContentTokenCount"] || 0,
      "total_tokens" => usage["totalTokenCount"] || 0
    }
    |> Map.merge(Map.take(usage, ["thoughtsTokenCount"]))
  end

  defp normalize_usage(_usage), do: nil

  defp blocks_to_content(blocks) when is_map(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, block} -> block end)
  end

  defp blocks_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join()
  end

  defp maybe_add_set(edits, resource, path, value, raw) when is_binary(value) do
    edits ++ [%Edit{op: :set, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_set(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_add_merge(edits, resource, path, value, raw) when is_map(value) do
    edits ++ [%Edit{op: :merge, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_merge(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_add_finish_reason(edits, finish_reason, raw) when is_binary(finish_reason) do
    edits ++
      [
        %Edit{
          op: :set,
          resource: ["message"],
          path: ["stop_reason"],
          value: normalize_finish_reason(finish_reason),
          raw: raw
        }
      ]
  end

  defp maybe_add_finish_reason(edits, _finish_reason, _raw), do: edits

  defp normalize_finish_reason(reason) when is_binary(reason) do
    reason
    |> Macro.underscore()
    |> String.downcase()
  end

  defp maybe_put(body, key, value, predicate) when is_function(predicate, 1) do
    if predicate.(value), do: Map.put(body, key, value), else: body
  end

  defp non_empty_list?(value), do: is_list(value) and value != []
  defp non_empty_map?(value), do: is_map(value) and map_size(value) > 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
end
