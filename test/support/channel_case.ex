defmodule FrothWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint FrothWeb.Endpoint
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Froth.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Froth.Repo, {:shared, self()})
    end

    :ok
  end
end
