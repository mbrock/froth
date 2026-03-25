defmodule Froth.LLM.Providers.OpenAI do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Message, Request, Store}

  @impl true
  def build_request(%Request{} = request) do
    body =
      %{
        "model" => request.model,
        "messages" => encode_messages(request.messages),
        "stream" => true
      }
      |> maybe_put("max_completion_tokens", request.max_tokens, &positive_integer?/1)
      |> maybe_put("tools", encode_tools(request.tools), &non_empty_list?/1)
      |> maybe_put(
        "stream_options",
        %{"include_usage" => true},
        fn _ -> request.provider_options["include_usage"] == true end
      )
      |> maybe_put(
        "reasoning_effort",
        request.provider_options["reasoning_effort"],
        &present_string?/1
      )

    body =
      case normalized_system_message(request.system) do
        nil -> body
        system_message -> Map.update(body, "messages", [system_message], &[system_message | &1])
      end

    {:ok, %{url: request.endpoint, headers: request.headers, body: body}}
  end

  @impl true
  def decode_payload(%{"choices" => [choice | _]} = payload, %Store{} = store)
      when is_map(choice) do
    delta = Map.get(choice, "delta", %{})
    finish_reason = Map.get(choice, "finish_reason")

    edits =
      []
      |> maybe_add_set(["message"], ["id"], payload["id"], payload)
      |> maybe_add_set(["message"], ["model"], payload["model"], payload)
      |> maybe_add_merge(["message"], ["usage"], payload["usage"], payload)
      |> maybe_add_text_delta(delta, payload)
      |> maybe_add_tool_call_deltas(delta, payload)
      |> maybe_add_finish_reason(finish_reason, payload)

    preview_store = Store.apply_edits(store, edits)
    edits = maybe_close_tool_calls(edits, finish_reason, preview_store, payload)

    {edits, false}
  end

  def decode_payload(%{"usage" => %{} = usage}, _store) do
    {[
       %Edit{
         op: :merge,
         resource: ["message"],
         path: ["usage"],
         value: usage,
         raw: %{"usage" => usage}
       }
     ], false}
  end

  def decode_payload(_payload, _store), do: {[], false}

  @impl true
  def finalize(%Store{} = store) do
    message = Store.get(store, ["message"], %{})
    text = Store.get(store, ["message", "text"], "")
    tool_calls = Store.get(store, ["message", "tool_calls"], %{})

    content =
      []
      |> maybe_add_text_block(text)
      |> Kernel.++(tool_calls_to_content(tool_calls))

    %{
      text: text,
      content: content,
      stop_reason: Map.get(message, "stop_reason"),
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
        attrs: %{"id" => id, "name" => name} = attrs
      })
      when is_binary(id) and is_binary(name) do
    {:tool_use_start, %{"id" => id, "name" => name, "input" => Map.get(attrs, "input", %{})}}
  end

  def project_event(%Edit{
        op: :append,
        resource: ["message", "tool_calls", _idx],
        path: ["arguments_json"],
        value: partial_json,
        attrs: %{"id" => id}
      })
      when is_binary(id) and is_binary(partial_json) do
    {:tool_use_delta, %{"id" => id, "partial_json" => partial_json}}
  end

  def project_event(%Edit{
        op: :close,
        resource: ["message", "tool_calls", _idx],
        attrs: %{"id" => id, "name" => name, "input" => input}
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
    Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(message) do
    case Message.normalize(message) do
      {:ok, %Message{} = normalized} -> encode_normalized_message(normalized)
      :error when is_map(message) -> [message]
      :error -> []
    end
  end

  defp encode_normalized_message(%Message{role: :system} = message) do
    [%{"role" => "system", "content" => Message.text_content(message)}]
  end

  defp encode_normalized_message(%Message{role: :user} = message) do
    content = encode_user_content(Message.content_blocks(message))
    tool_results = Message.tool_results(message)

    user_messages =
      if is_nil(content) do
        []
      else
        [%{"role" => "user", "content" => content}]
      end

    tool_messages =
      tool_results
      |> Enum.flat_map(fn
        %{"tool_use_id" => tool_use_id, "content" => tool_content}
        when is_binary(tool_use_id) ->
          [
            %{
              "role" => "tool",
              "tool_call_id" => tool_use_id,
              "content" => normalize_text_content(tool_content)
            }
          ]

        _ ->
          []
      end)

    user_messages ++ tool_messages
  end

  defp encode_normalized_message(%Message{role: :assistant} = message) do
    text = Message.text_content(message)
    tool_calls = assistant_tool_calls(Message.tool_uses(message))

    encoded =
      %{"role" => "assistant"}
      |> maybe_put("content", text, &(is_binary(&1) and &1 != ""))
      |> maybe_put("tool_calls", tool_calls, &non_empty_list?/1)

    [
      if(Map.has_key?(encoded, "content") or Map.has_key?(encoded, "tool_calls"),
        do: encoded,
        else: Map.put(encoded, "content", "")
      )
    ]
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

  defp normalize_text_content(content) do
    to_string(content)
  end

  defp encode_user_content(blocks) when is_list(blocks) do
    blocks =
      Enum.reject(blocks, fn
        %{"type" => "tool_result"} -> true
        _ -> false
      end)

    case encode_user_content_parts(blocks) do
      [] ->
        nil

      parts ->
        if Enum.all?(parts, &(&1["type"] == "text")) do
          Enum.map_join(parts, "", &Map.get(&1, "text", ""))
        else
          parts
        end
    end
  end

  defp encode_user_content(_blocks), do: nil

  defp encode_user_content_parts(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%{"type" => "text", "text" => text}]

      %{"type" => "image", "source" => source} = block when is_map(source) ->
        case openai_image_part(source, block) do
          nil -> []
          part -> [part]
        end

      %{"type" => "image_url"} = part ->
        [part]

      %{"text" => text} when is_binary(text) ->
        [%{"type" => "text", "text" => text}]

      _ ->
        []
    end)
  end

  defp openai_image_part(source, block) when is_map(source) and is_map(block) do
    url =
      cond do
        is_binary(source["url"]) and String.trim(source["url"]) != "" ->
          source["url"]

        is_binary(source["uri"]) and String.trim(source["uri"]) != "" ->
          source["uri"]

        is_binary(source["data"]) and String.trim(source["data"]) != "" ->
          media_type = source["media_type"] || source["mime_type"] || "image/jpeg"
          "data:#{media_type};base64,#{source["data"]}"

        true ->
          nil
      end

    if is_binary(url) and url != "" do
      %{"type" => "image_url", "image_url" => %{"url" => url}}
      |> maybe_put_detail(block)
    end
  end

  defp maybe_put_detail(part, %{"extra_content" => %{"openai" => %{"detail" => detail}}})
       when is_binary(detail) and detail != "" do
    put_in(part, ["image_url", "detail"], detail)
  end

  defp maybe_put_detail(part, _block), do: part

  defp assistant_tool_calls(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = tool_use
      when is_binary(id) and is_binary(name) and is_map(input) ->
        tool_call =
          %{
            "id" => id,
            "type" => "function",
            "function" => %{
              "name" => name,
              "arguments" => Jason.encode!(input)
            }
          }
          |> Map.merge(Map.drop(tool_use, ["type", "id", "name", "input"]))

        [tool_call]

      _ ->
        []
    end)
  end

  defp assistant_tool_calls(_content), do: []

  defp encode_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      # Pass through built-in tools (web_search, x_search) unchanged
      %{"type" => type} = tool when type != "function" ->
        tool

      tool ->
        %{
          "type" => "function",
          "function" => %{
            "name" => tool["name"],
            "description" => tool["description"],
            "parameters" => tool["input_schema"]
          }
        }
    end)
  end

  defp normalized_system_message(system) when is_binary(system) do
    system = String.trim(system)
    if system == "", do: nil, else: %{"role" => "system", "content" => system}
  end

  defp normalized_system_message(_system), do: nil

  defp maybe_add_set(edits, resource, path, value, raw) when is_binary(value) do
    edits ++ [%Edit{op: :set, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_set(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_add_merge(edits, resource, path, value, raw) when is_map(value) do
    edits ++ [%Edit{op: :merge, resource: resource, path: path, value: value, raw: raw}]
  end

  defp maybe_add_merge(edits, _resource, _path, _value, _raw), do: edits

  defp maybe_add_text_delta(edits, %{"content" => text}, raw)
       when is_binary(text) and text != "" do
    edits ++ [%Edit{op: :append, resource: ["message"], path: ["text"], value: text, raw: raw}]
  end

  defp maybe_add_text_delta(edits, _delta, _raw), do: edits

  defp maybe_add_tool_call_deltas(edits, %{"tool_calls" => tool_calls}, raw)
       when is_list(tool_calls) do
    Enum.reduce(tool_calls, edits, fn tool_call, acc ->
      idx = tool_call["index"] || 0
      function = Map.get(tool_call, "function", %{})
      attrs = tool_call_attrs(tool_call)

      acc =
        if map_size(attrs) > 0 do
          acc ++
            [%Edit{op: :open, resource: ["message", "tool_calls", idx], attrs: attrs, raw: raw}]
        else
          acc
        end

      case function["arguments"] do
        arguments when is_binary(arguments) and arguments != "" ->
          acc ++
            [
              %Edit{
                op: :append,
                resource: ["message", "tool_calls", idx],
                path: ["arguments_json"],
                value: arguments,
                attrs: attrs,
                raw: raw
              }
            ]

        _ ->
          acc
      end
    end)
  end

  defp maybe_add_tool_call_deltas(edits, _delta, _raw), do: edits

  defp maybe_add_finish_reason(edits, finish_reason, raw) when is_binary(finish_reason) do
    edits ++
      [
        %Edit{
          op: :set,
          resource: ["message"],
          path: ["stop_reason"],
          value: finish_reason,
          raw: raw
        }
      ]
  end

  defp maybe_add_finish_reason(edits, _finish_reason, _raw), do: edits

  defp maybe_close_tool_calls(edits, finish_reason, %Store{} = store, raw)
       when finish_reason in ["tool_calls", "stop"] do
    tool_calls = Store.get(store, ["message", "tool_calls"], %{})

    Enum.reduce(tool_calls, edits, fn {idx, tool_call}, acc ->
      input =
        case Map.get(tool_call, "arguments_json", "") do
          json when is_binary(json) and json != "" ->
            case Jason.decode(json) do
              {:ok, %{} = decoded} -> decoded
              _ -> %{}
            end

          _ ->
            %{}
        end

      attrs =
        tool_call
        |> Map.drop(["arguments_json", "input"])
        |> maybe_put_attr("input", input)

      acc ++ [%Edit{op: :close, resource: ["message", "tool_calls", idx], attrs: attrs, raw: raw}]
    end)
  end

  defp maybe_close_tool_calls(edits, _finish_reason, _store, _raw), do: edits

  defp tool_calls_to_content(tool_calls) when is_map(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {idx, _tool_call} -> idx end)
    |> Enum.flat_map(fn {_idx, tool_call} ->
      with id when is_binary(id) <- Map.get(tool_call, "id"),
           name when is_binary(name) <- Map.get(tool_call, "name") do
        input =
          case Map.get(tool_call, "arguments_json", "") do
            json when is_binary(json) and json != "" ->
              case Jason.decode(json) do
                {:ok, %{} = decoded} -> decoded
                _ -> %{}
              end

            _ ->
              Map.get(tool_call, "input", %{})
          end

        tool_use =
          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
          |> Map.merge(Map.drop(tool_call, ["id", "name", "type", "arguments_json", "input"]))

        [tool_use]
      else
        _ -> []
      end
    end)
  end

  defp maybe_add_text_block(content, text) when is_binary(text) and text != "" do
    content ++ [%{"type" => "text", "text" => text}]
  end

  defp maybe_add_text_block(content, _text), do: content

  defp maybe_put(body, key, value, predicate) when is_function(predicate, 1) do
    if predicate.(value), do: Map.put(body, key, value), else: body
  end

  defp tool_call_attrs(tool_call) when is_map(tool_call) do
    function = Map.get(tool_call, "function", %{})

    tool_call
    |> Map.drop(["index", "function"])
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
    |> maybe_put_attr("name", function["name"])
  end

  defp maybe_put_attr(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp non_empty_list?(value), do: is_list(value) and value != []
  defp positive_integer?(value), do: is_integer(value) and value > 0
end
