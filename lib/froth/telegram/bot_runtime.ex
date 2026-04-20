defmodule Froth.Telegram.BotRuntime do
  @moduledoc """
  Per-bot supervisor tree.

  Owns the bot worker process plus its private cycle supervisor so bot
  shutdown and restart semantics cover the whole subtree.
  """

  use Supervisor

  alias Froth.Telegram.Bot

  @bot_child_id :bot
  @cycles_sup_child_id :cycles_sup

  def child_spec(opts) when is_map(opts), do: child_spec(Map.to_list(opts))

  def child_spec(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) when is_map(opts), do: start_link(Map.to_list(opts))

  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    children = [
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one},
        id: @cycles_sup_child_id
      ),
      Supervisor.child_spec({Bot, Keyword.put(opts, :runtime_ref, self())},
        id: @bot_child_id
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
