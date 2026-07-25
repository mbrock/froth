defmodule Froth.Agent.CycleItem do
  use Ecto.Schema
  import Ecto.Changeset

  alias Froth.Agent.{Cycle, Message}

  @message_kinds ["message.user", "message.assistant"]
  @semantic_event_kinds %{
    "cycle.started" => "cycle.started",
    "cycle.completed" => "cycle.completed",
    "cycle.failed" => "cycle.failed",
    "cycle.cancelled" => "cycle.cancelled",
    "tool.started" => "tool.use",
    "tool.completed" => "tool.result",
    "tool.failed" => "tool.result",
    "tool.timed_out" => "tool.result",
    "control.outcome" => "control.outcome"
  }

  @primary_key {:id, Ecto.ULID, autogenerate: true}
  @foreign_key_type Ecto.ULID

  @type t :: %__MODULE__{
          id: String.t() | nil,
          cycle_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          role: :user | :agent | nil,
          item_kind: String.t() | nil,
          payload: map(),
          span_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "cycle_items" do
    belongs_to(:cycle, Cycle)
    field(:seq, :integer)
    field(:role, Ecto.Enum, values: [:user, :agent])
    field(:item_kind, :string)
    field(:payload, :map, default: %{})
    field(:span_id, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def message_changeset(item, cycle, seq, role, content, metadata)
      when role in [:user, :agent] do
    item_kind =
      if role == :user, do: "message.user", else: "message.assistant"

    changeset(item, %{
      cycle_id: cycle.id,
      seq: seq,
      role: role,
      item_kind: item_kind,
      payload: %{
        "content" => Message.wrap(content),
        "metadata" => metadata || %{}
      }
    })
  end

  def event_changeset(item, cycle, seq, kind, payload, span_id)
      when is_binary(kind) and is_map(payload) do
    changeset(item, %{
      cycle_id: cycle.id,
      seq: seq,
      item_kind: Map.fetch!(@semantic_event_kinds, kind),
      payload: payload,
      span_id: span_id
    })
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :cycle_id,
      :seq,
      :role,
      :item_kind,
      :payload,
      :span_id
    ])
    |> validate_required([:cycle_id, :seq, :item_kind, :payload])
    |> unique_constraint([:cycle_id, :seq])
  end

  def semantic_event_kind?(kind),
    do: Map.has_key?(@semantic_event_kinds, kind)

  def message_kind?(kind), do: kind in @message_kinds

  def to_message(%__MODULE__{} = item) do
    %Message{
      id: item.id,
      cycle_id: item.cycle_id,
      seq: item.seq,
      role: item.role,
      content: Map.get(item.payload, "content", []),
      metadata: empty_to_nil(Map.get(item.payload, "metadata")),
      inserted_at: item.inserted_at
    }
  end

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(value), do: value
end
