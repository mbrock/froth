defmodule Froth.Follow.Projector do
  @moduledoc """
  Thin shim kept only for historical call sites. Prefer
  `Froth.Follow.Entry.from_event/1` and `from_row/1` directly.
  """

  alias Froth.Follow.Entry

  @spec from_event(Froth.Event.t()) :: Entry.t()
  def from_event(event), do: Entry.from_event(event)

  @spec from_row(map()) :: Entry.t()
  def from_row(row), do: Entry.from_row(row)
end
