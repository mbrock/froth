defmodule FrothWeb.ComputePresence do
  use Phoenix.Presence,
    otp_app: :froth,
    pubsub_server: Froth.PubSub
end
