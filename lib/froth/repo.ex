defmodule Froth.Repo do
  use Ecto.Repo,
    otp_app: :froth,
    adapter: Ecto.Adapters.Postgres
end
