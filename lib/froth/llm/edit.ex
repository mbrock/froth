defmodule Froth.LLM.Edit do
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

  def full_path(%__MODULE__{resource: resource, path: path}), do: resource ++ path

  def resource_id(%__MODULE__{resource: resource}) do
    Enum.map_join(resource, "/", &to_string/1)
  end
end
