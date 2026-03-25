defmodule Froth.LLM.Providers.Anthropic do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM
  alias Froth.LLM.{Edit, Message, Request, Store}

  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def build_request(%Request{} = request) do
    {tools, mcp_servers} = split_tools(request.tools)

    body =
      %{
        "model" => request.model,
        "max_tokens" => request.max_tokens,
        "messages" => encode_messages(request.messages),
        "stream" => true
      }
      |> maybe_put("system", request.system, &present_string?/1)
      |> maybe_put("thinking", request.thinking, &is_map/1)
      |> maybe_put("output_config", request.output_config, &is_map/1)
      |> maybe_put("tools", tools, &non_empty_list?/1)
      |> maybe_put("mcp_servers", mcp_servers, &non_empty_list?/1)
      |> maybe_put("cache_control", request.cache_control, &is_map/1)

    {:ok, %{url: @api_url, headers: request.headers, body: body}}
  end

  @impl true
  def decode_payload(%{"type" => "message_stop"}, _store), do: {[], true}

  def decode_payload(%{"type" => "error"} = payload, _store) do
    {[%Edit{op: :set, resource: ["message"], path: ["error"], value: payload, raw: payload}],
     true}
  end

  def decode_payload(
        %{"type" => "message_start", "message" => %{} = message} = payload,
        _store
      ) do
    edits =
      [
        maybe_set(["message"], ["id"], message["id"], payload),
        maybe_set(["message"], ["model"], message["model"], payload),
        maybe_merge(["message"], ["usage"], Map.get(message, "usage"), payload),
        %Edit{
          op: :open,
          resource: ["message"],
          attrs: Map.drop(message, ["usage", "content"]),
          raw: payload
        }
      ]
      |> Enum.reject(&is_nil/1)

    {edits, false}
  end

  def decode_payload(%{"type" => "message_delta"} = payload, _store) do
    delta = Map.get(payload, "delta", %{})

    edits =
      [
        maybe_set(["message"], ["stop_reason"], Map.get(delta, "stop_reason"), payload),
        maybe_merge(["message"], ["usage"], Map.get(payload, "usage"), payload)
      ]
      |> Enum.reject(&is_nil/1)

    {edits, false}
  end

  def decode_payload(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "thinking"} = cb
        } = payload,
        _store
      )
      when is_integer(idx) do
    edits = [
      %Edit{
        op: :open,
        resource: ["message", "blocks", idx],
        attrs:
          cb
          |> Map.put_new("thinking", "")
          |> Map.put("__thinking_buf", "")
          |> Map.put("__signature_buf", ""),
        raw: payload
      }
    ]

    {edits, false}
  end

  def decode_payload(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => type} = cb
        } = payload,
        _store
      )
      when is_integer(idx) and type in ["tool_use", "mcp_tool_use"] do
    edits = [
      %Edit{
        op: :open,
        resource: ["message", "blocks", idx],
        attrs:
          cb
          |> Map.put_new("input", %{})
          |> Map.put("__input_json_buf", ""),
        raw: payload
      }
    ]

    {edits, false}
  end

  def decode_payload(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "mcp_tool_result"} = cb
        } = payload,
        _store
      )
      when is_integer(idx) do
    edits = [
      %Edit{
        op: :open,
        resource: ["message", "blocks", idx],
        attrs:
          cb
          |> Map.put_new("content", [])
          |> Map.put_new("is_error", false),
        raw: payload
      }
    ]

    {edits, false}
  end

  def decode_payload(
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => %{"type" => "text"}
        } = payload,
        _store
      )
      when is_integer(idx) do
    edits = [
      %Edit{
        op: :open,
        resource: ["message", "blocks", idx],
        attrs: %{"type" => "text", "text" => ""},
        raw: payload
      }
    ]

    {edits, false}
  end

  def decode_payload(
        %{"type" => "content_block_delta", "index" => idx} = payload,
        %Store{} = store
      )
      when is_integer(idx) do
    delta = Map.get(payload, "delta", %{})
    block = ["message", "blocks", idx]
    block_state = Store.get(store, block, %{})
    text_delta = extract_text_delta(payload)

    edits =
      cond do
        is_binary(text_delta) and text_delta != "" ->
          [
            %Edit{
              op: :append,
              resource: block,
              path: ["text"],
              value: text_delta,
              raw: payload
            }
          ]

        match?(%{"type" => "thinking_delta", "thinking" => _}, delta) ->
          [
            %Edit{
              op: :append,
              resource: block,
              path: ["__thinking_buf"],
              value: delta["thinking"],
              raw: payload
            }
          ]

        match?(%{"type" => "signature_delta", "signature" => _}, delta) ->
          [
            %Edit{
              op: :append,
              resource: block,
              path: ["__signature_buf"],
              value: delta["signature"],
              raw: payload
            }
          ]

        match?(%{"type" => "input_json_delta", "partial_json" => _}, delta) ->
          [
            %Edit{
              op: :append,
              resource: block,
              path: ["__input_json_buf"],
              value: delta["partial_json"],
              attrs:
                case Map.get(block_state, "id") do
                  id when is_binary(id) -> %{"id" => id}
                  _ -> %{}
                end,
              raw: payload
            }
          ]

        true ->
          []
      end

    {edits, false}
  end

  def decode_payload(
        %{"type" => "content_block_stop", "index" => idx} = payload,
        %Store{} = store
      )
      when is_integer(idx) do
    block_path = ["message", "blocks", idx]
    block = Store.get(store, block_path, %{})

    edits =
      case block do
        %{"type" => "thinking"} ->
          thinking = Map.get(block, "__thinking_buf", "")
          signature = Map.get(block, "__signature_buf", "")

          [
            %Edit{
              op: :set,
              resource: block_path,
              path: ["thinking"],
              value: thinking,
              raw: payload
            },
            %Edit{
              op: :set,
              resource: block_path,
              path: ["signature"],
              value: signature,
              raw: payload
            },
            %Edit{op: :delete, resource: block_path, path: ["__thinking_buf"], raw: payload},
            %Edit{op: :delete, resource: block_path, path: ["__signature_buf"], raw: payload},
            %Edit{
              op: :close,
              resource: block_path,
              attrs: %{
                "type" => "thinking",
                "thinking" => thinking,
                "signature" => signature,
                "index" => idx
              },
              raw: payload
            }
          ]

        %{"type" => type, "id" => id, "name" => name} = tool_block
        when type in ["tool_use", "mcp_tool_use"] ->
          input =
            case tool_block do
              %{"input" => %{} = input} when map_size(input) > 0 ->
                input

              %{"__input_json_buf" => buf} when is_binary(buf) and buf != "" ->
                case Jason.decode(buf) do
                  {:ok, %{} = input} -> input
                  _ -> %{}
                end

              _ ->
                %{}
            end

          [
            %Edit{op: :set, resource: block_path, path: ["input"], value: input, raw: payload},
            %Edit{op: :delete, resource: block_path, path: ["__input_json_buf"], raw: payload},
            %Edit{
              op: :close,
              resource: block_path,
              attrs:
                tool_block
                |> Map.take(["server_name"])
                |> Map.merge(%{"type" => type, "id" => id, "name" => name, "input" => input}),
              raw: payload
            }
          ]

        %{"type" => "mcp_tool_result"} = mcp_tool_result ->
          [
            %Edit{
              op: :close,
              resource: block_path,
              attrs:
                mcp_tool_result
                |> Map.put_new("content", [])
                |> Map.put_new("is_error", false),
              raw: payload
            }
          ]

        %{"type" => "text"} ->
          [
            %Edit{
              op: :close,
              resource: block_path,
              attrs: %{"type" => "text", "index" => idx, "text" => Map.get(block, "text", "")},
              raw: payload
            }
          ]

        _ ->
          []
      end

    {edits, false}
  end

  def decode_payload(_payload, _store), do: {[], false}

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
  def project_event(%Edit{op: :open, resource: ["message"], attrs: attrs}) when is_map(attrs) do
    with id when is_binary(id) <- attrs["id"],
         model when is_binary(model) <- attrs["model"] do
      {:message_start, %{"id" => id, "model" => model}}
    else
      _ -> nil
    end
  end

  def project_event(%Edit{op: :merge, resource: ["message"], path: ["usage"], value: usage})
      when is_map(usage) do
    {:usage, %{"usage" => usage}}
  end

  def project_event(%Edit{
        op: :open,
        resource: ["message", "blocks", idx],
        attrs: %{"type" => "thinking"}
      })
      when is_integer(idx) do
    {:thinking_start, %{"index" => idx}}
  end

  def project_event(%Edit{
        op: :append,
        resource: ["message", "blocks", idx],
        path: ["text"],
        value: text
      })
      when is_integer(idx) and is_binary(text) do
    {:text_delta, text}
  end

  def project_event(%Edit{
        op: :append,
        resource: ["message", "blocks", idx],
        path: ["__thinking_buf"],
        value: delta
      })
      when is_integer(idx) and is_binary(delta) do
    {:thinking_delta, %{"index" => idx, "delta" => delta}}
  end

  def project_event(
        %Edit{
          op: :append,
          resource: ["message", "blocks", _idx],
          path: ["__input_json_buf"],
          value: partial_json
        } = edit
      )
      when is_binary(partial_json) do
    case edit.attrs do
      %{"id" => id} when is_binary(id) ->
        {:tool_use_delta, %{"id" => id, "partial_json" => partial_json}}

      _ ->
        nil
    end
  end

  def project_event(%Edit{
        op: :open,
        resource: ["message", "blocks", _idx],
        attrs: %{"type" => type, "id" => id, "name" => name} = attrs
      })
      when is_binary(id) and is_binary(name) and type in ["tool_use", "mcp_tool_use"] do
    {:tool_use_start,
     %{
       "type" => type,
       "id" => id,
       "name" => name,
       "input" => Map.get(attrs, "input")
     }
     |> maybe_put("server_name", Map.get(attrs, "server_name"), &present_string?/1)}
  end

  def project_event(%Edit{
        op: :close,
        resource: ["message", "blocks", idx],
        attrs: %{"type" => "thinking", "thinking" => thinking, "signature" => signature}
      })
      when is_integer(idx) do
    {:thinking_stop, %{"index" => idx, "thinking" => thinking, "signature" => signature}}
  end

  def project_event(%Edit{
        op: :close,
        resource: ["message", "blocks", _idx],
        attrs: %{"type" => type, "id" => id, "name" => name, "input" => input} = attrs
      })
      when is_binary(id) and is_binary(name) and type in ["tool_use", "mcp_tool_use"] do
    {:tool_use_stop,
     %{
       "type" => type,
       "id" => id,
       "name" => name,
       "input" => input
     }
     |> maybe_put("server_name", Map.get(attrs, "server_name"), &present_string?/1)}
  end

  def project_event(_edit), do: nil

  def encode_messages(messages) when is_list(messages) do
    Enum.flat_map(messages, &encode_message/1)
  end

  defp encode_message(message) do
    case Message.normalize(message) do
      {:ok, %Message{role: :system}} ->
        []

      {:ok, %Message{role: role} = normalized} ->
        [
          %{
            "role" => encode_role(role),
            "content" => encode_content_blocks(Message.content_blocks(normalized))
          }
        ]

      :error when is_map(message) ->
        [message]

      :error ->
        []
    end
  end

  def blocks_to_content(blocks) when is_map(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, block} ->
      block
      |> Map.delete("__input_json_buf")
      |> Map.delete("__input_json")
      |> Map.delete("__thinking_buf")
      |> Map.delete("__signature_buf")
      |> Map.delete("index")
    end)
  end

  def extract_text_delta(%{"delta" => %{"text" => text}}) when is_binary(text), do: text

  def extract_text_delta(%{"type" => "content_block_delta", "delta" => %{"text" => text}})
      when is_binary(text),
      do: text

  def extract_text_delta(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => text}
      })
      when is_binary(text),
      do: text

  def extract_text_delta(_), do: nil

  defp blocks_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join()
  end

  defp maybe_put(body, key, value, predicate) when is_function(predicate, 1) do
    if predicate.(value), do: Map.put(body, key, value), else: body
  end

  defp maybe_set(resource, path, value, raw) when is_binary(value) do
    %Edit{op: :set, resource: resource, path: path, value: value, raw: raw}
  end

  defp maybe_set(_resource, _path, _value, _raw), do: nil

  defp maybe_merge(resource, path, value, raw) when is_map(value) do
    %Edit{op: :merge, resource: resource, path: path, value: value, raw: raw}
  end

  defp maybe_merge(_resource, _path, _value, _raw), do: nil

  defp encode_content_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, &encode_content_block/1)
  end

  defp encode_content_block(%{"type" => type, "content" => content} = block)
       when type in ["tool_result", "mcp_tool_result"] do
    Map.put(block, "content", encode_tool_result_content(content))
  end

  defp encode_content_block(block), do: block

  defp split_tools(tools) when is_list(tools) do
    tools
    |> Enum.reduce({[], []}, fn
      %{"type" => "mcp_endpoint"} = tool, {encoded_tools, mcp_servers} ->
        {
          [encode_mcp_toolset(tool) | encoded_tools],
          [encode_mcp_server(tool) | mcp_servers]
        }

      tool, {encoded_tools, mcp_servers} when is_map(tool) ->
        {[tool | encoded_tools], mcp_servers}

      _, acc ->
        acc
    end)
    |> then(fn {encoded_tools, mcp_servers} ->
      {Enum.reverse(encoded_tools), Enum.reverse(mcp_servers)}
    end)
  end

  defp split_tools(_tools), do: {[], []}

  defp encode_mcp_server(tool) when is_map(tool) do
    %{
      "type" => "url",
      "url" => mcp_server_url(tool),
      "name" => mcp_server_name(tool)
    }
    |> maybe_put("authorization_token", mcp_authorization_token(tool), &present_string?/1)
  end

  defp encode_mcp_toolset(tool) when is_map(tool) do
    default_config =
      tool
      |> mcp_default_config()
      |> maybe_put_map("enabled", if(allowlist_present?(tool), do: false, else: nil))
      |> maybe_put_map("defer_loading", Map.get(tool, "defer_loading", true))

    configs =
      tool
      |> Map.get("configs", %{})
      |> normalize_tool_configs()
      |> maybe_enable_allowed_tools(mcp_allowed_tools(tool))

    %{
      "type" => "mcp_toolset",
      "mcp_server_name" => mcp_server_name(tool)
    }
    |> maybe_put("default_config", default_config, &non_empty_map?/1)
    |> maybe_put("configs", configs, &non_empty_map?/1)
    |> maybe_put("cache_control", Map.get(tool, "cache_control"), &is_map/1)
  end

  defp mcp_default_config(%{"default_config" => %{} = default_config}),
    do: stringify_map(default_config)

  defp mcp_default_config(_tool), do: %{}

  defp mcp_server_name(tool) when is_map(tool) do
    Map.get(tool, "name") || Map.get(tool, "server_name")
  end

  defp mcp_server_url(tool) when is_map(tool) do
    Map.get(tool, "url") || Map.get(tool, "server_url")
  end

  defp mcp_authorization_token(tool) when is_map(tool) do
    Map.get(tool, "bearer_token") ||
      Map.get(tool, "authorization_token") ||
      resolve_bearer_token_provider(Map.get(tool, "bearer_token_provider"))
  end

  defp resolve_bearer_token_provider(provider) when is_binary(provider) and provider != "" do
    LLM.active_api_key(provider)
  end

  defp resolve_bearer_token_provider(_provider), do: nil

  defp mcp_allowed_tools(tool) when is_map(tool) do
    tool
    |> Map.get("allowed_tools", Map.get(tool, "tools"))
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp allowlist_present?(tool), do: mcp_allowed_tools(tool) != []

  defp maybe_enable_allowed_tools(configs, []), do: configs

  defp maybe_enable_allowed_tools(configs, allowed_tools) when is_map(configs) do
    Enum.reduce(allowed_tools, configs, fn tool_name, acc ->
      Map.update(acc, tool_name, %{"enabled" => true}, fn config ->
        Map.put_new(config, "enabled", true)
      end)
    end)
  end

  defp normalize_tool_configs(configs) when is_map(configs) do
    Map.new(configs, fn
      {name, %{} = config} -> {to_string(name), stringify_map(config)}
      {name, _config} -> {to_string(name), %{}}
    end)
  end

  defp normalize_tool_configs(_configs), do: %{}

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_map_value(value)}
    end)
  end

  defp stringify_map_value(%{} = map), do: stringify_map(map)
  defp stringify_map_value(list) when is_list(list), do: Enum.map(list, &stringify_map_value/1)
  defp stringify_map_value(value), do: value

  defp encode_tool_result_content(content) when is_binary(content), do: content

  defp encode_tool_result_content(content) when is_list(content) do
    if Enum.all?(content, &content_block?/1) do
      Enum.map(content, &encode_content_block/1)
    else
      encode_jsonish(content)
    end
  end

  defp encode_tool_result_content(%{"type" => _type} = block), do: [encode_content_block(block)]
  defp encode_tool_result_content(%{"text" => _text} = block), do: [encode_content_block(block)]
  defp encode_tool_result_content(%{} = content), do: encode_jsonish(content)
  defp encode_tool_result_content(content), do: to_string(content)

  defp content_block?(%{"type" => _type}), do: true
  defp content_block?(%{"text" => _text}), do: true
  defp content_block?(_), do: false

  defp encode_jsonish(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> inspect(value, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp encode_role(:user), do: "user"
  defp encode_role(:assistant), do: "assistant"
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp non_empty_list?(value), do: is_list(value) and value != []
  defp non_empty_map?(value), do: is_map(value) and map_size(value) > 0
end
