defmodule Froth.Telegram.Bots do
  @moduledoc """
  Runtime manager for Telegram bot workers.

  Each bot runs through its profile module and is registered by bot id.
  """

  use Supervisor

  alias Froth.Telegram.Charlie
  alias Froth.Telemetry.Span

  @registry Froth.Telegram.BotRegistry
  @supervisor Froth.Telegram.BotSupervisor

  def start_link(_opts) do
    case Supervisor.start_link(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} = ok ->
        case auto_start_bots() do
          :ok ->
            ok

          {:error, reason} = error ->
            Span.execute(
              [:froth, :telegram, :bots, :autostart_failed],
              nil,
              %{reason: reason}
            )

            Supervisor.stop(pid)
            error
        end

      other ->
        other
    end
  end

  @impl true
  def init([]) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def via(bot_id) when is_binary(bot_id),
    do: {:via, Registry, {@registry, bot_id}}

  def start_bot(config) when is_map(config) do
    bot_id = Map.fetch!(config, :id)
    runtime_module = Map.get(config, :runtime_module, Charlie)

    child_config =
      config
      |> Map.delete(:runtime_module)
      |> Map.put_new(:name, via(bot_id))

    DynamicSupervisor.start_child(@supervisor, {runtime_module, child_config})
  end

  def stop_bot(bot_id) when is_binary(bot_id) do
    case Registry.lookup(@registry, bot_id) do
      [{pid, _}] ->
        case DynamicSupervisor.terminate_child(@supervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            case runtime_pid(pid) do
              runtime_pid when is_pid(runtime_pid) ->
                DynamicSupervisor.terminate_child(@supervisor, runtime_pid)

              nil ->
                {:error, :not_found}
            end

          other ->
            other
        end

      [] ->
        {:error, :not_found}
    end
  end

  def list_bots do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def cast(bot_id, message) when is_binary(bot_id) do
    case Registry.lookup(@registry, bot_id) do
      [{pid, _}] ->
        GenServer.cast(pid, message)

      [] ->
        :ok
    end
  end

  defp runtime_pid(pid) when is_pid(pid) do
    GenServer.call(pid, :runtime_ref)
  catch
    :exit, _reason -> nil
  end

  defp auto_start_bots do
    configured_bots()
    |> Enum.reduce_while(:ok, fn config, :ok ->
      case start_bot(config) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, reason} ->
          bot_id = Map.get(config, :id, "unknown")

          Span.execute([:froth, :telegram, :bots, :start_failed], nil, %{
            bot_id: bot_id,
            reason: reason
          })

          {:halt, {:error, {:bot_start_failed, bot_id, reason}}}
      end
    end)
  end

  defp configured_bots do
    bots =
      :froth
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:bots, [])

    case bots do
      [] -> []
      list when is_list(list) -> list
    end
  end
end
