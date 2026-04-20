defmodule Froth.LogTranslatorTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Froth.{LogTranslator, Repo}

  setup tags do
    Repo.put_test_context(tags)

    owner = Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, owner: owner}
  end

  test "annotates sandbox ownership warnings with allow context", %{owner: owner} do
    parent = self()

    child =
      spawn(fn ->
        Repo.allow(parent, "translator child")
        send(parent, {:child_ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:child_ready, ^child}, 5_000
    assert %{label: "translator child"} = Repo.allow_debug_context(child)

    message = """
    owner #{inspect(owner)} exited

    Client #{inspect(child)} (:proc_lib) is still using a connection from owner
    """

    assert {:ok, translated} = LogTranslator.translate(:debug, :error, :string, message)

    output = IO.iodata_to_binary(translated)

    assert output =~ "Repo sandbox context:"
    assert output =~ "translator child"
    assert output =~ "test annotates sandbox ownership warnings with allow context"
    assert output =~ "test/froth/log_translator_test.exs:16"

    send(child, :stop)
  end

  test "annotates sandbox client-exit warnings with allow context" do
    parent = self()

    child =
      spawn(fn ->
        Repo.allow(parent, "translator child")
        send(parent, {:child_ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:child_ready, ^child}, 5_000
    assert %{label: "translator child"} = Repo.allow_debug_context(child)

    ref = Process.monitor(child)
    send(child, :stop)
    assert_receive {:DOWN, ^ref, :process, ^child, :normal}, 5_000
    assert %{label: "translator child"} = Repo.allow_debug_context(child)

    message = "client #{inspect(child)} exited"

    assert {:ok, translated} = LogTranslator.translate(:debug, :error, :string, message)

    output = IO.iodata_to_binary(translated)

    assert output =~ "Repo sandbox context:"
    assert output =~ "translator child"
    assert output =~ "test annotates sandbox client-exit warnings with allow context"
  end
end
