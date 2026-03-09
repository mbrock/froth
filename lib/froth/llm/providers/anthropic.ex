defmodule Froth.LLM.Providers.Anthropic do
  @moduledoc false

  @behaviour Froth.LLM.Provider

  alias Froth.LLM.{Edit, Request, Store}

  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def build_request(%Request{} = request) do
    body =
      %{
        "model" => request.model,
        "max_tokens" => request.max_tokens,
        "messages" => request.messages,
        "stream" => true
      }
      |> maybe_put("system", request.system, &present_string?/1)
      |> maybe_put("thinking", request.thinking, &is_map/1)
      |> maybe_put("output_config", request.output_config, &is_map/1)
      |> maybe_put("tools", request.tools, &non_empty_list?/1)
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
          "content_block" => %{"type" => "tool_use"} = cb
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

        %{"type" => "tool_use", "id" => id, "name" => name} ->
          input =
            case block do
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
              attrs: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input},
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
        attrs: %{"type" => "tool_use", "id" => id, "name" => name} = attrs
      })
      when is_binary(id) and is_binary(name) do
    {:tool_use_start, %{"id" => id, "name" => name, "input" => Map.get(attrs, "input")}}
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
        attrs: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      })
      when is_binary(id) and is_binary(name) do
    {:tool_use_stop, %{"id" => id, "name" => name, "input" => input}}
  end

  def project_event(_edit), do: nil

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

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp non_empty_list?(value), do: is_list(value) and value != []
end
