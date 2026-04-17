defmodule Froth.Context.Block do
  @moduledoc """
  One part of a tool's return value.

  Tools emit a list of blocks. A block is a keyword list of
  attributes (headers, like MIME parts), an optional binary body, and
  optional child blocks. The tool does not measure bodies, does not
  decide whether content should be blobbed, and does not render
  anything.

  Downstream, `Froth.Context.Blocks.materialize/1` decides storage
  form (inline vs blob-backed), and `Froth.Context.BlockHTML`
  components decide presentation (rich for the live cycle, compact
  for the post-cycle trace view).

  The ordering of `attrs` is preserved on the wire so renderers can
  keep conventionally-first keys (`:kind`, ids, etc.) in front.
  """

  @type attr_value :: String.t() | integer() | boolean() | nil | [String.t()]
  @type attrs :: [{atom(), attr_value()}]

  @type t :: %__MODULE__{
          attrs: attrs(),
          body: binary() | nil,
          children: [t()]
        }

  defstruct attrs: [], body: nil, children: []

  @doc "Convenience constructor."
  @spec new(attrs(), binary() | nil, [t()]) :: t()
  def new(attrs \\ [], body \\ nil, children \\ []),
    do: %__MODULE__{attrs: attrs, body: body, children: children}

  @doc "Look up an attribute value."
  @spec attr(t(), atom(), term()) :: term()
  def attr(%__MODULE__{attrs: attrs}, key, default \\ nil) when is_atom(key) do
    Keyword.get(attrs, key, default)
  end

  @doc """
  Encode a block as a JSON-safe map. Used to persist a materialized
  block inside `events.metadata.result`.

  The body is assumed to already be a binary or nil by the time this
  runs — Materialize is responsible for externalizing bodies that
  shouldn't end up in JSONB.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{attrs: attrs, body: body, children: children}) do
    %{
      "shape" => "block",
      "attrs" => encode_attrs(attrs),
      "body" => body,
      "children" => Enum.map(children, &to_map/1)
    }
  end

  @doc """
  Rehydrate a block from a map produced by `to_map/1` (or a direct
  JSONB decode). Returns `nil` if the map isn't recognizable as a
  block.
  """
  @spec from_map(any()) :: t() | nil
  def from_map(%{"shape" => "block"} = map) do
    %__MODULE__{
      attrs: decode_attrs(Map.get(map, "attrs", [])),
      body: Map.get(map, "body"),
      children:
        map
        |> Map.get("children", [])
        |> Enum.map(&from_map/1)
        |> Enum.reject(&is_nil/1)
    }
  end

  def from_map(_), do: nil

  defp encode_attrs(attrs) when is_list(attrs) do
    Enum.map(attrs, fn {k, v} -> %{"k" => to_string(k), "v" => encode_value(v)} end)
  end

  defp encode_attrs(_), do: []

  defp decode_attrs(attrs) when is_list(attrs) do
    Enum.flat_map(attrs, fn
      %{"k" => k, "v" => v} -> [{safe_atom(k), decode_value(v)}]
      {k, v} when is_binary(k) -> [{safe_atom(k), decode_value(v)}]
      _ -> []
    end)
  end

  defp decode_attrs(_), do: []

  # Atoms used in attrs come from tool authors in this codebase (not
  # from untrusted input), so `String.to_atom` is fine here.
  defp safe_atom(key) when is_atom(key), do: key
  defp safe_atom(key) when is_binary(key), do: String.to_atom(key)

  defp encode_value(v) when is_binary(v) or is_integer(v) or is_boolean(v) or is_nil(v), do: v

  defp encode_value(v) when is_list(v) do
    Enum.map(v, &encode_value/1)
  end

  defp encode_value(v), do: to_string(v)

  defp decode_value(v), do: v
end
