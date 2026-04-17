defmodule Froth.AnthropicCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Froth.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Froth.Repo, {:shared, self()})

    Froth.Repo.insert!(%Froth.ApiKey{
      name: "test-anthropic",
      provider: "anthropic",
      key: "test-key-not-real"
    })

    :ok
  end
end
