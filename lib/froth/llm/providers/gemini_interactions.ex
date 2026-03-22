defmodule Froth.LLM.Providers.GeminiInteractions do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Message, Request, Store}

  @media_types ["image", "audio", "document", "video"]

  @impl true
  def build_request(%Request{} = request) do
    body =
      %{
        "model" => request.model,
        "input" => encode_messages(request.messages),
        "stream" => true
      }
      |> maybe_put("system_instruction", system_instruction(request.system), &non_empty_binary?/1)
      |> maybe_put("tools", encode_tools(request.tools), &non_empty_list?/1)
      |> maybe_put("generation_config", generation_config(request), &non_empty_map?/1)
      |> maybe_put(
        "response_modalities",
        normalize_response_modalities(request.response_modalities),
        &non_empty_list?/1
      )
      |> maybe_put("response_format", request.response_format, &is_map/1)
      |> maybe_put("response_mime_type", request.response_mime_type, &non_empty_binary?/1)

    {:ok, %{url: request.endpoint, headers: request.headers, body: body}}
  end

  @impl true
  def decode_payload(
        %{"event_type" => "interaction.start", "interaction" => interaction} = payload,
        _store
      )
      when is_map(interaction) do
    edits =
      []
      |> maybe_add_set(["message"], ["id"], interaction["id"], payload)
      |> maybe_add_set(["message"], ["model"], interaction["model"], payload)

    {edits, false}
  end

  def decode_payload(
        %{"event_type" => "content.start", "index" => idx, "content" => content} = payload,
        _store
      )
      when is_integer(idx) and is_map(content) do
    edits =
      case content_start_attrs(content) do
        attrs when is_map(attrs) ->
          [%Edit{op: :open, resource: ["message", "blocks", idx], attrs: attrs, raw: payload}]

        _ ->
          []
      end

    {edits, false}
  end

  def decode_payload(
        %{"event_type" => "content.delta", "index" => idx, "delta" => delta} = payload,
        %Store{} = store
      )
      when is_integer(idx) and is_map(delta) do
    block_path = ["message", "blocks", idx]
    current_block = Store.get(store, block_path, %{})

    edits =
      case delta["type"] do
        "text" ->
          []
          |> maybe_open_text_block(block_path, current_block, payload)
          |> maybe_add_append(block_path, ["text"], delta["text"], payload)

        type when type in @media_types ->
          []
          |> maybe_open_media_block(block_path, current_block, type, payload)
          |> maybe_add_set(block_path, ["mime_type"], delta["mime_type"], payload)
          |> maybe_add_set(block_path, ["resolution"], delta["resolution"], payload)
          |> maybe_add_set(block_path, ["uri"], delta["uri"], payload)
          |> maybe_add_append(block_path, ["data"], delta["data"], payload)

        "function_call" ->
          function_call_edits(block_path, delta, payload)

        _ ->
          []
      end

    {edits, false}
  end

  def decode_payload(
        %{"event_type" => "content.stop", "index" => idx} = payload,
        %Store{} = store
      )
      when is_integer(idx) do
    block_path = ["message", "blocks", idx]
    current_block = Store.get(store, block_path, %{})

    edits =
      cond do
        current_block == %{} ->
          []

        current_block["type"] == "tool_use" ->
          []

        true ->
          [%Edit{op: :close, resource: block_path, attrs: current_block, raw: payload}]
      end

    {edits, false}
  end

  def decode_payload(
        %{"event_type" => "interaction.complete", "interaction" => interaction} = payload,
        _store
      )
      when is_map(interaction) do
    edits =
      []
      |> maybe_add_set(["message"], ["id"], interaction["id"], payload)
      |> maybe_add_set(["message"], ["model"], interaction["model"], payload)
      |> maybe_add_merge(["message"], ["usage"], normalize_usage(interaction["usage"]), payload)
      |> maybe_add_set(
        ["message"],
        ["stop_reason"],
        normalize_stop_reason(interaction["status"]),
        payload
      )

    {edits, false}
  end

  def decode_payload(%{"event_type" => "interaction.status_update"}, _store), do: {[], false}

  def decode_payload(%{"event_type" => "error", "error" => error}, _store) when is_map(error) do
    raise "Gemini interactions error: #{error["message"] || inspect(error)}"
  end

  def decode_payload(_payload, _store), do: {[], false}

  @impl true
  def finalize(%Store{} = store) do
    message = Store.get(store, ["message"], %{})
    blocks = Store.get(store, ["message", "blocks"], %{})

    content =
      blocks
      |> blocks_to_content()
      |> Enum.map(&normalize_output_block/1)
      |> Enum.reject(&is_nil/1)

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
    {turns, _tool_uses} =
      Enum.reduce(messages, {[], %{}}, fn message, {turns, tool_uses} ->
        {encoded_turns, next_tool_uses} = encode_message(message, tool_uses)
        {turns ++ encoded_turns, next_tool_uses}
      end)

    turns
  end

  defp encode_message(message, tool_uses) do
    case Message.normalize(message) do
      {:ok, %Message{} = normalized} ->
        encode_normalized_message(normalized, tool_uses)

      :error ->
        encode_raw_message(message, tool_uses)
    end
  end

  defp encode_normalized_message(%Message{role: :system}, tool_uses), do: {[], tool_uses}

  defp encode_normalized_message(%Message{role: role} = message, tool_uses)
       when role in [:user, :assistant] do
    {content, tool_uses} = encode_content_blocks(Message.content_blocks(message), role, tool_uses)

    if content == [] do
      {[], tool_uses}
    else
      {[%{"role" => encode_role(role), "content" => content}], tool_uses}
    end
  end

  defp encode_raw_message(%{"role" => role, "content" => content}, tool_uses)
       when role in ["user", "assistant", "model"] do
    normalized_role =
      case role do
        "user" -> :user
        "assistant" -> :assistant
        "model" -> :assistant
      end

    {encoded_content, tool_uses} = encode_content_blocks(content, normalized_role, tool_uses)

    if encoded_content == [] do
      {[], tool_uses}
    else
      {[%{"role" => encode_role(normalized_role), "content" => encoded_content}], tool_uses}
    end
  end

  defp encode_raw_message(_message, tool_uses), do: {[], tool_uses}

  defp encode_content_blocks(content, _role, tool_uses) when is_binary(content) do
    {[%{"type" => "text", "text" => content}], tool_uses}
  end

  defp encode_content_blocks(content, role, tool_uses) when is_list(content) do
    Enum.reduce(content, {[], tool_uses}, fn block, {encoded, current_tool_uses} ->
      {content_block, next_tool_uses} = encode_content_block(block, role, current_tool_uses)

      if is_nil(content_block) do
        {encoded, next_tool_uses}
      else
        {encoded ++ [content_block], next_tool_uses}
      end
    end)
  end

  defp encode_content_blocks(content, _role, tool_uses) when is_map(content) do
    {[
       %{
         "type" => "text",
         "text" => inspect(content, limit: :infinity, printable_limit: :infinity)
       }
     ], tool_uses}
  end

  defp encode_content_blocks(content, _role, tool_uses) do
    {[%{"type" => "text", "text" => to_string(content)}], tool_uses}
  end

  defp encode_content_block(%{"type" => "text", "text" => text}, _role, tool_uses)
       when is_binary(text) do
    {%{"type" => "text", "text" => text}, tool_uses}
  end

  defp encode_content_block(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block,
         :assistant,
         tool_uses
       )
       when is_binary(id) and is_binary(name) and is_map(input) do
    signature = google_signature(block)

    encoded =
      %{
        "type" => "function_call",
        "id" => id,
        "name" => name,
        "arguments" => input
      }
      |> maybe_put("signature", signature, &non_empty_binary?/1)

    tool_use =
      %{"id" => id, "name" => name, "input" => input}
      |> maybe_put("signature", signature, &non_empty_binary?/1)

    {encoded, Map.put(tool_uses, id, tool_use)}
  end

  defp encode_content_block(
         %{"type" => "tool_result", "tool_use_id" => tool_use_id} = block,
         :user,
         tool_uses
       )
       when is_binary(tool_use_id) do
    tool_use = Map.get(tool_uses, tool_use_id, %{})

    encoded =
      %{
        "type" => "function_result",
        "call_id" => tool_use_id,
        "result" => encode_tool_result_content(block["content"])
      }
      |> maybe_put("name", block["name"] || tool_use["name"], &non_empty_binary?/1)
      |> maybe_put("is_error", block["is_error"], &(&1 == true))
      |> maybe_put(
        "signature",
        google_signature(block) || tool_use["signature"],
        &non_empty_binary?/1
      )

    {encoded, tool_uses}
  end

  defp encode_content_block(
         %{"type" => "function_call", "id" => id, "name" => name, "arguments" => arguments} =
           block,
         :assistant,
         tool_uses
       )
       when is_binary(id) and is_binary(name) and is_map(arguments) do
    tool_use =
      %{"id" => id, "name" => name, "input" => arguments}
      |> maybe_put("signature", block["signature"], &non_empty_binary?/1)

    {block, Map.put(tool_uses, id, tool_use)}
  end

  defp encode_content_block(%{"type" => "function_result"} = block, :user, tool_uses),
    do: {block, tool_uses}

  defp encode_content_block(%{"type" => type} = block, _role, tool_uses)
       when type in @media_types do
    {encode_media_block(block), tool_uses}
  end

  defp encode_content_block(%{"text" => text}, _role, tool_uses) when is_binary(text) do
    {%{"type" => "text", "text" => text}, tool_uses}
  end

  defp encode_content_block(_block, _role, tool_uses), do: {nil, tool_uses}

  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "model"

  defp encode_media_block(%{"source" => source} = block) when is_map(source) do
    type = block["type"]
    media_type = source["media_type"] || source["mime_type"]

    %{"type" => type}
    |> maybe_put("data", source["data"], &non_empty_binary?/1)
    |> maybe_put(
      "uri",
      source["url"] || source["uri"],
      &non_empty_binary?/1
    )
    |> maybe_put("mime_type", media_type, &non_empty_binary?/1)
  end

  defp encode_media_block(%{"type" => type} = block) when type in @media_types do
    block
    |> Map.take(["type", "data", "uri", "mime_type", "resolution"])
    |> maybe_put("type", type, &non_empty_binary?/1)
  end

  defp encode_tool_result_content(content) when is_list(content) do
    case encode_tool_result_blocks(content) do
      [] -> normalize_text_content(content)
      blocks -> blocks
    end
  end

  defp encode_tool_result_content(%{"type" => _} = content) do
    case encode_tool_result_blocks([content]) do
      [] -> normalize_text_content(content)
      [block] -> [block]
      blocks -> blocks
    end
  end

  defp encode_tool_result_content(content) when is_map(content), do: content
  defp encode_tool_result_content(content) when is_binary(content), do: content
  defp encode_tool_result_content(content), do: to_string(content)

  defp encode_tool_result_blocks(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%{"type" => "text", "text" => text}]

      %{"type" => type} = block when type in @media_types ->
        [encode_media_block(block)]

      %{"text" => text} when is_binary(text) ->
        [%{"type" => "text", "text" => text}]

      _ ->
        []
    end)
  end

  defp encode_tools([]), do: []

  defp encode_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn tool ->
      case encode_tool(tool) do
        nil -> []
        encoded -> [encoded]
      end
    end)
  end

  defp encode_tools(_tools), do: []

  defp encode_tool(%{"type" => "web_search"}),
    do: %{"type" => "google_search", "search_types" => ["web_search"]}

  defp encode_tool(%{"type" => "google_search"} = tool),
    do: Map.put_new(tool, "type", "google_search")

  defp encode_tool(%{"type" => "code_execution"} = tool), do: tool
  defp encode_tool(%{"type" => "url_context"} = tool), do: tool
  defp encode_tool(%{"type" => "computer_use"} = tool), do: tool
  defp encode_tool(%{"type" => "mcp_server"} = tool), do: tool

  defp encode_tool(tool) when is_map(tool) do
    %{
      "type" => "function",
      "name" => tool["name"],
      "description" => tool["description"],
      "parameters" => tool["input_schema"]
    }
  end

  defp encode_tool(_tool), do: nil

  defp generation_config(%Request{} = request) do
    %{}
    |> maybe_put("max_output_tokens", request.max_tokens, &positive_integer?/1)
  end

  defp content_start_attrs(%{"type" => "text"}), do: %{"type" => "text", "text" => ""}
  defp content_start_attrs(%{"type" => type}) when type in @media_types, do: %{"type" => type}
  defp content_start_attrs(_content), do: nil

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

  defp maybe_open_media_block(edits, block_path, current_block, type, payload) do
    if current_block["type"] == type do
      edits
    else
      edits ++ [%Edit{op: :open, resource: block_path, attrs: %{"type" => type}, raw: payload}]
    end
  end

  defp function_call_edits(
         block_path,
         %{"id" => id, "name" => name, "arguments" => arguments} = delta,
         payload
       )
       when is_binary(id) and is_binary(name) and is_map(arguments) do
    attrs =
      %{
        "type" => "tool_use",
        "id" => id,
        "name" => name,
        "input" => arguments
      }
      |> maybe_put_extra_content(delta)

    [
      %Edit{op: :open, resource: block_path, attrs: attrs, raw: payload},
      %Edit{op: :close, resource: block_path, attrs: attrs, raw: payload}
    ]
  end

  defp function_call_edits(_block_path, _delta, _payload), do: []

  defp maybe_put_extra_content(attrs, %{"signature" => signature}) when is_binary(signature) do
    Map.put(attrs, "extra_content", %{"google" => %{"thought_signature" => signature}})
  end

  defp maybe_put_extra_content(attrs, _delta), do: attrs

  defp google_signature(%{
         "extra_content" => %{"google" => %{"thought_signature" => signature}}
       })
       when is_binary(signature) do
    signature
  end

  defp google_signature(%{"signature" => signature}) when is_binary(signature), do: signature
  defp google_signature(_block), do: nil

  defp normalize_response_modalities(modalities) when is_list(modalities) do
    modalities
    |> Enum.flat_map(fn
      modality when is_atom(modality) ->
        [modality |> Atom.to_string() |> String.downcase()]

      modality when is_binary(modality) ->
        modality = modality |> String.trim() |> String.downcase()
        if modality == "", do: [], else: [modality]

      _ ->
        []
    end)
  end

  defp normalize_response_modalities(modality) when is_atom(modality) do
    [modality |> Atom.to_string() |> String.downcase()]
  end

  defp normalize_response_modalities(modality) when is_binary(modality) do
    modality = modality |> String.trim() |> String.downcase()
    if modality == "", do: [], else: [modality]
  end

  defp normalize_response_modalities(_modalities), do: []

  defp normalize_usage(%{"total_input_tokens" => _} = usage) do
    %{
      "input_tokens" => usage["total_input_tokens"] || 0,
      "output_tokens" => usage["total_output_tokens"] || 0,
      "cache_read_input_tokens" => usage["total_cached_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0
    }
    |> Map.merge(
      Map.take(usage, [
        "input_tokens_by_modality",
        "output_tokens_by_modality",
        "total_thought_tokens",
        "total_tool_use_tokens"
      ])
    )
  end

  defp normalize_usage(_usage), do: nil

  defp normalize_stop_reason("completed"), do: "stop"

  defp normalize_stop_reason(status) when is_binary(status) do
    status
    |> Macro.underscore()
    |> String.downcase()
  end

  defp normalize_stop_reason(_status), do: nil

  defp normalize_output_block(%{"type" => type} = block) when type in @media_types do
    source =
      cond do
        non_empty_binary?(block["data"]) ->
          %{
            "type" => "base64",
            "media_type" => block["mime_type"],
            "data" => block["data"]
          }

        non_empty_binary?(block["uri"]) ->
          %{
            "type" => "url",
            "media_type" => block["mime_type"],
            "url" => block["uri"]
          }

        true ->
          nil
      end

    %{"type" => type}
    |> maybe_put("source", source, &is_map/1)
    |> maybe_put("extra_content", media_extra_content(block), &non_empty_map?/1)
  end

  defp normalize_output_block(%{"type" => "text", "text" => text} = block) when is_binary(text) do
    Map.put(block, "text", text)
  end

  defp normalize_output_block(block) when is_map(block), do: block
  defp normalize_output_block(_block), do: nil

  defp media_extra_content(%{"resolution" => resolution}) when is_binary(resolution) do
    %{"google" => %{"resolution" => resolution}}
  end

  defp media_extra_content(_block), do: nil

  defp blocks_to_content(blocks) when is_map(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _block} -> idx end)
    |> Enum.map(fn {_idx, block} -> block end)
  end

  defp blocks_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join()
  end

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

  defp system_instruction(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: nil, else: system
  end

  defp system_instruction(_system), do: nil

  defp maybe_add_set(edits, resource, path, value, raw) when is_binary(value) do
    edits ++ [%Edit{op: :set, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_set(edits, resource, path, value, raw) when is_integer(value) do
    edits ++ [%Edit{op: :set, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_set(edits, resource, path, value, raw) when is_map(value) do
    edits ++ [%Edit{op: :set, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_set(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_add_append(edits, resource, path, value, raw) when is_binary(value) do
    edits ++ [%Edit{op: :append, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_append(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_add_merge(edits, resource, path, value, raw) when is_map(value) do
    edits ++ [%Edit{op: :merge, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_merge(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_put(body, key, value, predicate) when is_function(predicate, 1) do
    if predicate.(value), do: Map.put(body, key, value), else: body
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
  defp non_empty_list?(value), do: is_list(value) and value != []
  defp non_empty_map?(value), do: is_map(value) and map_size(value) > 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
end
