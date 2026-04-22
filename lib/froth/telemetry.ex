defmodule Froth.Telemetry do
  @moduledoc """
  Froth emits events through `Span` (see `lib/span.ex`), which writes
  them to the `events` table and broadcasts them on the `"events"`
  pub/sub topic. Subscribers like `Froth.Telemetry.Logger` and
  `FrothWeb.FollowLive` live on the pub/sub side.

  The `:telemetry` library is not used as an internal bus; this
  module only exists to keep the historical call site tidy.
  """

  def attach_handlers, do: :ok
end
