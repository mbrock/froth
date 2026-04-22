defmodule Froth.Web.LightpandaTest do
  use ExUnit.Case, async: true

  alias Froth.Web.Lightpanda

  setup tags do
    Froth.Repo.put_test_context(tags)

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        Froth.Repo,
        shared: not tags[:async]
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "fetch/2" do
    test "returns :missing_executable when lightpanda is off PATH" do
      previous_path = System.get_env("PATH")
      System.put_env("PATH", "/var/empty")

      try do
        assert {:error, :missing_executable} =
                 Lightpanda.fetch("https://example.test/", timeout_ms: 1_000)
      after
        if previous_path, do: System.put_env("PATH", previous_path)
      end
    end
  end
end
