defmodule Froth.Agent.Message do
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          role: :user | :agent,
          content: term(),
          parent_id: String.t() | nil
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @foreign_key_type Ecto.ULID

  schema "agent_messages" do
    field(:role, Ecto.Enum, values: [:user, :agent])
    field(:content, :map)
    field(:metadata, :map)
    belongs_to(:parent, __MODULE__)
    timestamps()
  end

  def user(content), do: %__MODULE__{role: :user, content: wrap(content)}
  def agent(content), do: %__MODULE__{role: :agent, content: wrap(content)}

  def agent(content, metadata),
    do: %__MODULE__{role: :agent, content: wrap(content), metadata: metadata}

  def to_api(%__MODULE__{role: :user, content: content}) do
    %{"role" => "user", "content" => unwrap(content)}
  end

  def to_api(%__MODULE__{role: :agent, content: content}) do
    %{"role" => "assistant", "content" => unwrap(content)}
  end

  def wrap(value) when is_map(value), do: value
  def wrap(value), do: %{"_wrapped" => value}

  def extract_text(%__MODULE__{content: content}), do: extract_text(content)

  def extract_text(%{"_wrapped" => value}), do: extract_text(value)

  def extract_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  def extract_text(text) when is_binary(text), do: text
  def extract_text(_), do: nil

  defp unwrap(%{"_wrapped" => value}), do: value
  defp unwrap(map) when is_map(map), do: map
end
