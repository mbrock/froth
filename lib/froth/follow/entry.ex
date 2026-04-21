defmodule Froth.Follow.Entry do
  @moduledoc false

  @type mode :: :smart | :raw | :errors

  @type t :: %__MODULE__{
          id: term(),
          at: DateTime.t() | NaiveDateTime.t() | nil,
          event: String.t(),
          family: String.t(),
          kind: String.t(),
          level: :debug | :info | :warn | :error,
          scope: String.t() | nil,
          summary: String.t(),
          detail: String.t() | nil,
          duration_ms: integer() | nil,
          cycle_id: String.t() | nil,
          span_id: String.t() | nil,
          parent_id: String.t() | nil,
          tool_use_id: String.t() | nil,
          message_id: String.t() | nil,
          measurements: map(),
          metadata: map(),
          hidden: boolean()
        }

  defstruct [
    :id,
    :at,
    :event,
    :family,
    :kind,
    :level,
    :scope,
    :summary,
    :detail,
    :duration_ms,
    :cycle_id,
    :span_id,
    :parent_id,
    :tool_use_id,
    :message_id,
    measurements: %{},
    metadata: %{},
    hidden: false
  ]

  def visible?(%__MODULE__{}, :raw), do: true

  def visible?(%__MODULE__{level: level}, :errors),
    do: level in [:warn, :error]

  def visible?(%__MODULE__{hidden: true}, :smart), do: false
  def visible?(%__MODULE__{}, :smart), do: true
end
