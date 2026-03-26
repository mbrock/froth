defmodule Froth.LLM.Providers.OpenAIResponses do
  @moduledoc """
  Provider for the OpenAI/xAI Responses API (`/v1/responses`).

  Both OpenAI and xAI implement the same Responses API wire format,
  so this single provider handles both vendors.
  """

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Message, Request, Store}

  @retryable_response_statuses ["failed", "incomplete"]

  # -- build_request --

  @impl true
  def build_request(%Request{} = request) do
    body =
      %{
        "model" => request.model,
        "input" => encode_messages(request.messages),
        "store" => true,
        "stream" => true
      }
      |> maybe_put("instructions", normalize_instructions(request.system))
      |> maybe_put("tools", encode_tools(request.tools))
      |> maybe_put("max_output_tokens", normalize_max_output_tokens(request.max_tokens))
      |> maybe_put(
        "reasoning",
        reasoning_config(
          request.provider_options["reasoning_effort"],
          request.provider_options["reasoning_summary"]
        )
      )
      |> maybe_put("previous_response_id", request.provider_options["previous_response_id"])
      |> maybe_put("text", text_config(request.provider_options["text_verbosity"]))

    {:ok, %{url: request.endpoint, headers: request.headers, body: body}}
  end

  # -- decode_payload --

  @impl true

  # Error events
  def decode_payload(%{"type" => "error", "error" => %{} = error} = payload, _store) do
    {provider_error_edits(%{"error" => error}, payload), true}
  end

  def decode_payload(
        %{"type" => "response.failed", "response" => %{"error" => %{} = error} = response} =
          payload,
        _store
      ) do
    error_value =
      %{"error" => error}
      |> maybe_put("response_id", response["id"])
      |> maybe_put("status", response["status"])

    {provider_error_edits(error_value, payload), true}
  end

  def decode_payload(
        %{"type" => "response.completed", "response" => %{"error" => %{} = error} = response} =
          payload,
        _store
      ) do
    if response["status"] in @retryable_response_statuses do
      error_value =
        %{"error" => error}
        |> maybe_put("response_id", response["id"])
        |> maybe_put("status", response["status"])

      {provider_error_edits(error_value, payload), true}
    else
      {[], false}
    end
  end

  # Text delta
  def decode_payload(%{"type" => "response.output_text.delta", "delta" => delta}, _store) do
    {[%Edit{op: :append, resource: ["message"], path: ["text"], value: delta}], false}
  end

  # Tool call argument streaming
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

  # Tool call added
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

  # Tool call done
  def decode_payload(
        %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item},
        _store
      ) do
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

  # Response completed — usage, stop reason, response_id, reasoning summary
  def decode_payload(%{"type" => "response.completed", "response" => resp} = _payload, _store)
      when is_map(resp) do
    usage = Map.get(resp, "usage", %{})

    edits =
      [
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
      ] ++ response_id_edits(resp) ++ reasoning_summary_edits(resp["output"])

    {edits, false}
  end

  # Ignored event types
  def decode_payload(%{"type" => "response.output_text.done"}, _store), do: {[], false}
  def decode_payload(%{"type" => "response.content_part" <> _}, _store), do: {[], false}

  # Catch-all
  def decode_payload(_payload, _store), do: {[], false}

  # -- finalize --

  @impl true
  def finalize(%Store{} = store) do
    text = Store.get(store, ["message", "text"], "")
    tool_calls = Store.get(store, ["message", "tool_calls"], %{})
    message = Store.get(store, ["message"], %{})
    response_id = Store.get(store, ["message", "response_id"])
    reasoning_summary = Store.get(store, ["message", "reasoning_summary"])

    content =
      []
      |> maybe_add_text_block(text)
      |> Kernel.++(tool_calls_to_content(tool_calls))
      |> maybe_prepend_reasoning_block(reasoning_summary)

    %{
      text: text,
      content: content,
      stop_reason: Map.get(message, "stop_reason", "end_turn"),
      usage: Map.get(message, "usage", %{}),
      model: Map.get(message, "model"),
      message_id: response_id || Map.get(message, "id")
    }
    |> maybe_put(:reasoning_summary, reasoning_summary)
    |> maybe_put(:response_id, response_id)
  end

  # -- Private helpers --

  defp provider_error_edits(error_value, payload) when is_map(error_value) do
    [
      %Edit{
        op: :set,
        resource: ["message"],
        path: ["error"],
        value: error_value,
        raw: payload
      }
    ]
  end

  defp response_id_edits(resp) when is_map(resp) do
    case Map.get(resp, "id") do
      response_id when is_binary(response_id) and response_id != "" ->
        [
          %Edit{op: :set, resource: ["message"], path: ["response_id"], value: response_id},
          %Edit{op: :set, resource: ["message"], path: ["id"], value: response_id}
        ]

      _ ->
        []
    end
  end

  defp reasoning_summary_edits(output) when is_list(output) do
    case extract_reasoning_summary(output) do
      "" ->
        []

      reasoning_summary ->
        [
          %Edit{
            op: :set,
            resource: ["message"],
            path: ["reasoning_summary"],
            value: reasoning_summary
          }
        ]
    end
  end

  defp reasoning_summary_edits(_output), do: []

  defp extract_reasoning_summary(output) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "reasoning", "summary" => summary} when is_list(summary) ->
        Enum.flat_map(summary, &extract_reasoning_summary_part/1)

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp extract_reasoning_summary_part(%{"type" => "summary_text", "text" => text})
       when is_binary(text),
       do: [text]

  defp extract_reasoning_summary_part(%{"text" => text}) when is_binary(text), do: [text]
  defp extract_reasoning_summary_part(_part), do: []

  defp maybe_prepend_reasoning_block(content, reasoning_summary)
       when is_list(content) and is_binary(reasoning_summary) and reasoning_summary != "" do
    [%{"type" => "thinking", "thinking" => reasoning_summary} | content]
  end

  defp maybe_prepend_reasoning_block(content, _reasoning_summary) when is_list(content),
    do: content

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

  defp maybe_add_text_block(blocks, ""), do: blocks
  defp maybe_add_text_block(blocks, text), do: blocks ++ [%{"type" => "text", "text" => text}]

  # -- Message encoding --

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

  defp encode_normalized_message(%Message{role: :system} = message) do
    encode_text_message("system", Message.content_blocks(message))
  end

  defp encode_normalized_message(%Message{role: :assistant} = message) do
    encode_text_message("assistant", Message.content_blocks(message)) ++
      encode_tool_call_items(Message.tool_uses(message))
  end

  defp encode_normalized_message(%Message{role: :user} = message) do
    encode_user_message(Message.content_blocks(message)) ++
      encode_tool_result_items(Message.tool_results(message))
  end

  defp encode_raw_message(%{"role" => "tool", "tool_use_id" => id, "content" => content}) do
    [%{"type" => "function_call_output", "call_id" => id, "output" => normalize_output(content)}]
  end

  defp encode_raw_message(%{"role" => "user", "content" => content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp encode_raw_message(%{"role" => "user", "content" => content}) when is_list(content) do
    encode_user_message(content) ++
      encode_tool_result_items(Enum.filter(content, &match?(%{"type" => "tool_result"}, &1)))
  end

  defp encode_raw_message(%{"role" => role, "content" => content}) when is_binary(content) do
    [%{"role" => role, "content" => content}]
  end

  defp encode_raw_message(%{"role" => role, "content" => content}) when is_list(content) do
    text_items = encode_text_message(role, content)

    tool_call_items =
      encode_tool_call_items(Enum.filter(content, &match?(%{"type" => "tool_use"}, &1)))

    tool_result_items =
      encode_tool_result_items(Enum.filter(content, &match?(%{"type" => "tool_result"}, &1)))

    text_items ++ tool_call_items ++ tool_result_items
  end

  defp encode_raw_message(message), do: [message]

  defp encode_text_message(role, content) when is_binary(role) do
    case normalize_text_content(content) do
      "" -> []
      text -> [%{"role" => role, "content" => text}]
    end
  end

  defp encode_user_message(content) do
    case encode_user_content(content) do
      nil -> []
      encoded -> [%{"role" => "user", "content" => encoded}]
    end
  end

  defp encode_user_content(content) when is_binary(content), do: content

  defp encode_user_content(content) when is_list(content) do
    content =
      Enum.reject(content, fn
        %{"type" => "tool_result"} -> true
        _ -> false
      end)

    case encode_user_content_parts(content) do
      [] ->
        nil

      parts ->
        if Enum.all?(parts, &(&1["type"] == "input_text")) do
          Enum.map_join(parts, "\n", &Map.get(&1, "text", ""))
        else
          parts
        end
    end
  end

  defp encode_user_content(content), do: normalize_text_content(content)

  defp encode_user_content_parts(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%{"type" => "input_text", "text" => text}]

      %{"type" => "input_text", "text" => text} = part when is_binary(text) ->
        [part]

      %{"type" => "input_image"} = part ->
        [part]

      %{"type" => "image", "source" => source} when is_map(source) ->
        case responses_image_part(source) do
          nil -> []
          part -> [part]
        end

      %{"type" => "image_url"} = part ->
        case normalize_image_url_part(part) do
          nil -> []
          image_part -> [image_part]
        end

      %{"text" => text} when is_binary(text) ->
        [%{"type" => "input_text", "text" => text}]

      _ ->
        []
    end)
  end

  # -- Tool encoding --

  defp encode_tools(tools) when is_list(tools) do
    tools
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn
      %{"type" => "mcp_endpoint"} ->
        []

      %{"type" => type} = tool when type != "function" ->
        [
          Map.drop(
            tool,
            Enum.filter(["name", "description", "input_schema"], &Map.has_key?(tool, &1))
          )
        ]

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

  # -- Normalization helpers --

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

  defp reasoning_config(nil, nil), do: nil
  defp reasoning_config("", nil), do: nil

  defp reasoning_config(effort, summary) do
    %{}
    |> maybe_put("effort", blank_to_nil(effort))
    |> maybe_put("summary", blank_to_nil(summary))
    |> case do
      config when map_size(config) == 0 -> nil
      config -> config
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp text_config(nil), do: nil
  defp text_config(""), do: nil
  defp text_config(verbosity) when is_binary(verbosity), do: %{"verbosity" => verbosity}
  defp text_config(_), do: nil

  defp responses_image_part(source) when is_map(source) do
    image_url =
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

    cond do
      is_binary(image_url) and image_url != "" ->
        %{"type" => "input_image", "image_url" => image_url}

      is_binary(source["file_id"]) and String.trim(source["file_id"]) != "" ->
        %{"type" => "input_image", "file_id" => source["file_id"]}

      true ->
        nil
    end
  end

  defp normalize_image_url_part(%{"image_url" => %{"url" => url}})
       when is_binary(url) and url != "" do
    %{"type" => "input_image", "image_url" => url}
  end

  defp normalize_image_url_part(%{"image_url" => url}) when is_binary(url) and url != "" do
    %{"type" => "input_image", "image_url" => url}
  end

  defp normalize_image_url_part(_part), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
