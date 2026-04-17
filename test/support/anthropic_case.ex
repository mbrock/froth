defmodule Froth.AnthropicCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  setup tags do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        Froth.Repo,
        shared: not tags[:async]
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    Froth.Repo.insert!(%Froth.ApiKey{
      name: "test-anthropic",
      provider: "anthropic",
      key: "test-key-not-real"
    })

    :ok
  end
end
