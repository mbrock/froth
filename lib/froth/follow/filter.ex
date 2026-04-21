defmodule Froth.Follow.Filter do
  @moduledoc false

  alias Froth.Follow.Entry

  @type t :: %__MODULE__{
          event_prefix: String.t() | nil,
          cycle_id: String.t() | nil,
          span_id: String.t() | nil
        }

  defstruct event_prefix: nil, cycle_id: nil, span_id: nil

  def new(opts \\ []) do
    %__MODULE__{
      event_prefix: normalize(Keyword.get(opts, :event_prefix)),
      cycle_id: normalize(Keyword.get(opts, :cycle_id)),
      span_id: normalize(Keyword.get(opts, :span_id))
    }
  end

  def matches?(%Entry{} = entry, %__MODULE__{} = filter) do
    matches_prefix?(entry, filter.event_prefix) and
      matches_id?(entry.cycle_id, filter.cycle_id) and
      matches_id?(entry.span_id, filter.span_id)
  end

  def event_segments(%__MODULE__{event_prefix: nil}), do: nil

  def event_segments(%__MODULE__{event_prefix: prefix}) do
    prefix
    |> String.split(".")
    |> Enum.reject(&(&1 == ""))
  end

  def summary(%__MODULE__{} = filter) do
    [
      filter.event_prefix && "event=#{filter.event_prefix}",
      filter.cycle_id && "cycle=#{filter.cycle_id}",
      filter.span_id && "span=#{filter.span_id}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp matches_prefix?(_entry, nil), do: true

  defp matches_prefix?(%Entry{event: event}, prefix),
    do: String.starts_with?(event, prefix)

  defp matches_id?(_value, nil), do: true
  defp matches_id?(nil, _prefix), do: false
  defp matches_id?(value, prefix), do: String.starts_with?(value, prefix)

  defp normalize(nil), do: nil

  defp normalize(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
