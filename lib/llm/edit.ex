defmodule LLM.Edit do
  @moduledoc false

  @type op :: :open | :set | :append | :merge | :delete | :close

  @type t :: %__MODULE__{
          op: op(),
          resource: [String.t() | integer()],
          path: [String.t() | integer()],
          value: term(),
          attrs: map(),
          raw: map() | nil
        }

  defstruct op: :set,
            resource: [],
            path: [],
            value: nil,
            attrs: %{},
            raw: nil

  def full_path(%__MODULE__{resource: resource, path: path}),
    do: resource ++ path

  def resource_id(%__MODULE__{resource: resource}) do
    Enum.map_join(resource, "/", &to_string/1)
  end

  @doc "Project an Edit into a caller-facing event tuple, or nil."
  def project_event(%__MODULE__{} = edit) do
    do_project(edit)
  end

  # -- text_delta: append text on any message-scoped path --

  defp do_project(%__MODULE__{
         op: :append,
         resource: ["message"],
         path: ["text"],
         value: text
       })
       when is_binary(text),
       do: {:text_delta, text}

  defp do_project(%__MODULE__{
         op: :append,
         resource: ["message", "blocks", idx],
         path: ["text"],
         value: text
       })
       when is_integer(idx) and is_binary(text),
       do: {:text_delta, text}

  # -- tool_use_start: open on tool_calls or blocks --

  defp do_project(%__MODULE__{
         op: :open,
         resource: ["message", "tool_calls", _idx],
         attrs: %{"id" => id, "name" => name} = attrs
       })
       when is_binary(id) and is_binary(name) do
    {:tool_use_start,
     %{"id" => id, "name" => name, "input" => Map.get(attrs, "input", %{})}}
  end

  defp do_project(%__MODULE__{
         op: :open,
         resource: ["message", "blocks", _idx],
         attrs: %{"type" => type, "id" => id, "name" => name} = attrs
       })
       when is_binary(id) and is_binary(name) and type == "tool_use" do
    {:tool_use_start,
     %{
       "type" => type,
       "id" => id,
       "name" => name,
       "input" => Map.get(attrs, "input")
     }}
  end

  # -- tool_use_delta: partial JSON on tool_calls or blocks --

  defp do_project(%__MODULE__{
         op: :append,
         resource: ["message", "tool_calls", _idx],
         path: ["arguments_json"],
         value: partial_json,
         attrs: %{"id" => id}
       })
       when is_binary(id) and is_binary(partial_json),
       do: {:tool_use_delta, %{"id" => id, "partial_json" => partial_json}}

  defp do_project(%__MODULE__{
         op: :append,
         resource: ["message", "blocks", _idx],
         path: ["__input_json_buf"],
         value: partial_json,
         attrs: %{"id" => id}
       })
       when is_binary(id) and is_binary(partial_json),
       do: {:tool_use_delta, %{"id" => id, "partial_json" => partial_json}}

  # -- tool_use_stop: close on tool_calls or blocks --

  defp do_project(%__MODULE__{
         op: :close,
         resource: ["message", "tool_calls", _idx],
         attrs: %{"id" => id, "name" => name, "input" => input}
       })
       when is_binary(id) and is_binary(name),
       do: {:tool_use_stop, %{"id" => id, "name" => name, "input" => input}}

  defp do_project(%__MODULE__{
         op: :close,
         resource: ["message", "blocks", _idx],
         attrs: %{
           "type" => type,
           "id" => id,
           "name" => name,
           "input" => input
         }
       })
       when is_binary(id) and is_binary(name) and type == "tool_use" do
    {:tool_use_stop,
     %{"type" => type, "id" => id, "name" => name, "input" => input}}
  end

  # -- usage --

  defp do_project(%__MODULE__{
         op: :merge,
         resource: ["message"],
         path: ["usage"],
         value: usage
       })
       when is_map(usage),
       do: {:usage, %{"usage" => usage}}

  # -- message_start (Anthropic) --

  defp do_project(%__MODULE__{op: :open, resource: ["message"], attrs: attrs})
       when is_map(attrs) do
    with id when is_binary(id) <- attrs["id"],
         model when is_binary(model) <- attrs["model"] do
      {:message_start, %{"id" => id, "model" => model}}
    else
      _ -> nil
    end
  end

  # -- thinking (Anthropic) --

  defp do_project(%__MODULE__{
         op: :open,
         resource: ["message", "blocks", idx],
         attrs: %{"type" => "thinking"}
       })
       when is_integer(idx),
       do: {:thinking_start, %{"index" => idx}}

  defp do_project(%__MODULE__{
         op: :append,
         resource: ["message", "blocks", idx],
         path: ["__thinking_buf"],
         value: delta
       })
       when is_integer(idx) and is_binary(delta),
       do: {:thinking_delta, %{"index" => idx, "delta" => delta}}

  defp do_project(%__MODULE__{
         op: :close,
         resource: ["message", "blocks", idx],
         attrs: %{
           "type" => "thinking",
           "thinking" => thinking,
           "signature" => signature
         }
       })
       when is_integer(idx),
       do:
         {:thinking_stop,
          %{"index" => idx, "thinking" => thinking, "signature" => signature}}

  # -- reasoning_summary (OpenAI) --

  defp do_project(%__MODULE__{
         op: :set,
         resource: ["message"],
         path: ["reasoning_summary"],
         value: summary
       })
       when is_binary(summary) and summary != "",
       do: {:thinking_summary, %{"thinking" => summary}}

  # -- fallback --

  defp do_project(_edit), do: nil
end
