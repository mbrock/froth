defmodule Froth.Agent.Cycle do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [
    :queued,
    :running,
    :waiting_on_tools,
    :awaiting_user_input,
    :completed,
    :failed,
    :cancelled
  ]

  @type status ::
          :queued
          | :running
          | :waiting_on_tools
          | :awaiting_user_input
          | :completed
          | :failed
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: status(),
          provider: String.t() | nil,
          model: String.t() | nil,
          root_span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          config: map(),
          system_prompt_hash: String.t() | nil,
          system_prompt_ref: String.t() | nil,
          toolset_hash: String.t() | nil,
          usage: map(),
          cost_usd: float() | nil,
          error: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}

  schema "agent_cycles" do
    field(:status, Ecto.Enum, values: @statuses, default: :queued)
    field(:provider, :string)
    field(:model, :string)
    field(:root_span_id, :string)
    field(:parent_span_id, :string)
    field(:config, :map, source: :config_json, default: %{})
    field(:system_prompt_hash, :string)
    field(:system_prompt_ref, :string)
    field(:toolset_hash, :string)
    field(:usage, :map, source: :usage_json, default: %{})
    field(:cost_usd, :float)
    field(:error, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(cycle, attrs) do
    cycle
    |> cast(attrs, [
      :status,
      :provider,
      :model,
      :root_span_id,
      :parent_span_id,
      :config,
      :system_prompt_hash,
      :system_prompt_ref,
      :toolset_hash,
      :usage,
      :cost_usd,
      :error,
      :started_at,
      :finished_at
    ])
  end
end
