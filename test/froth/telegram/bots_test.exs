defmodule Froth.Telegram.BotsTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.{Bots, Charlie}

  defmodule DummyBot do
    use GenServer

    def child_spec(opts) when is_map(opts) do
      %{
        id: {__MODULE__, Map.fetch!(opts, :id)},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) when is_map(opts) do
      name = Map.get(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      send(Map.fetch!(opts, :notify), {:dummy_bot_started, opts})
      {:ok, opts}
    end
  end

  test "default profile configs declare their runtime and tool modules" do
    assert Charlie.default_config().runtime_module == Charlie
    assert Charlie.default_config().model == "claude-opus-4-6"
    refute Map.has_key?(Charlie.default_config(), :failure_report_model)

    assert Charlie.default_config().tools_module ==
             Froth.Telegram.Toolsets.Charlie

    assert is_list(Charlie.default_config().tools_module.specs_for_api())

    assert Enum.any?(
             Charlie.default_config().tools_module.specs_for_api(),
             &(&1["name"] == "send_message")
           )
  end

  test "start_bot honors the configured runtime module" do
    bot_id = "dummy-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             Bots.start_bot(%{
               id: bot_id,
               runtime_module: DummyBot,
               notify: self()
             })

    assert_receive {:dummy_bot_started, %{id: ^bot_id}}, 1_000
    assert bot_id in Bots.list_bots()

    assert :ok = Bots.stop_bot(bot_id)
  end
end
