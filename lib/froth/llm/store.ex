defmodule Froth.LLM.Store do
  @moduledoc false

  alias Froth.LLM.Edit

  @type path_segment :: String.t() | integer()
  @type t :: %__MODULE__{
          doc: map(),
          resources: %{optional(String.t()) => map()}
        }

  defstruct doc: %{}, resources: %{}

  def new, do: %__MODULE__{}

  def get(%__MODULE__{doc: doc}, path, default \\ nil) when is_list(path) do
    get_in_path(doc, path, default)
  end

  def apply_edits(%__MODULE__{} = store, edits) when is_list(edits) do
    Enum.reduce(edits, store, &apply_edit(&2, &1))
  end

  def apply_edit(%__MODULE__{} = store, %Edit{op: :open} = edit) do
    value =
      case edit.attrs do
        attrs when is_map(attrs) and map_size(attrs) > 0 -> attrs
        _ -> %{}
      end

    store
    |> put_resource(edit, :open)
    |> update_doc(edit.resource, %{}, fn current ->
      current = normalize_map(current)
      deep_merge(current, value)
    end)
  end

  def apply_edit(%__MODULE__{} = store, %Edit{op: :set} = edit) do
    update_doc(store, Edit.full_path(edit), nil, fn _current -> edit.value end)
  end

  def apply_edit(%__MODULE__{} = store, %Edit{op: :append} = edit) do
    update_doc(store, Edit.full_path(edit), "", fn current ->
      to_string(current || "") <> to_string(edit.value || "")
    end)
  end

  def apply_edit(%__MODULE__{} = store, %Edit{op: :merge} = edit) do
    update_doc(store, Edit.full_path(edit), %{}, fn current ->
      deep_merge(normalize_map(current), normalize_map(edit.value))
    end)
  end

  def apply_edit(%__MODULE__{} = store, %Edit{op: :delete} = edit) do
    %{store | doc: delete_in_path(store.doc, Edit.full_path(edit))}
  end

  def apply_edit(%__MODULE__{} = store, %Edit{op: :close} = edit) do
    store =
      case edit.attrs do
        attrs when is_map(attrs) and map_size(attrs) > 0 ->
          update_doc(store, edit.resource, %{}, fn current ->
            deep_merge(normalize_map(current), attrs)
          end)

        _ ->
          store
      end

    put_resource(store, edit, :closed)
  end

  defp put_resource(%__MODULE__{} = store, %Edit{} = edit, status) do
    resource_id = Edit.resource_id(edit)

    resource =
      store.resources
      |> Map.get(resource_id, %{"resource" => edit.resource})
      |> Map.put("status", to_string(status))
      |> Map.put("resource", edit.resource)
      |> maybe_put_attrs(edit.attrs)

    %{store | resources: Map.put(store.resources, resource_id, resource)}
  end

  defp maybe_put_attrs(resource, attrs)
       when is_map(attrs) and map_size(attrs) > 0 do
    Map.put(resource, "attrs", attrs)
  end

  defp maybe_put_attrs(resource, _attrs), do: resource

  defp update_doc(%__MODULE__{} = store, path, default, fun)
       when is_list(path) do
    %{store | doc: update_in_path(store.doc, path, default, fun)}
  end

  defp update_in_path(doc, [key], default, fun) when is_map(doc) do
    Map.put(doc, key, fun.(Map.get(doc, key, default)))
  end

  defp update_in_path(doc, [key | rest], default, fun) when is_map(doc) do
    child = doc |> Map.get(key, %{}) |> normalize_map()
    Map.put(doc, key, update_in_path(child, rest, default, fun))
  end

  defp update_in_path(_doc, [], _default, fun), do: fun.(nil)

  defp get_in_path(doc, [key], default) when is_map(doc),
    do: Map.get(doc, key, default)

  defp get_in_path(doc, [key | rest], default) when is_map(doc) do
    case Map.get(doc, key) do
      %{} = child -> get_in_path(child, rest, default)
      nil -> default
      _other -> default
    end
  end

  defp get_in_path(_doc, [], default), do: default
  defp get_in_path(_doc, _path, default), do: default

  defp delete_in_path(doc, [key]) when is_map(doc), do: Map.delete(doc, key)

  defp delete_in_path(doc, [key | rest]) when is_map(doc) do
    case Map.get(doc, key) do
      %{} = child -> Map.put(doc, key, delete_in_path(child, rest))
      _ -> doc
    end
  end

  defp delete_in_path(doc, _path), do: doc

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        deep_merge(left_val, right_val)
      else
        right_val
      end
    end)
  end

  defp normalize_map(%{} = value), do: value
  defp normalize_map(_value), do: %{}
end
