defmodule Froth.Agent do
  @moduledoc """
  Context for agentic cycles: data access and the public `run` entry point.
  """

  import Ecto.Query
  alias Froth.Agent.{Config, Cycle, Event, Message, Worker}
  alias Froth.Repo

  @spec run(Message.t(), Config.t()) :: {Cycle.t(), Enumerable.t()}
  def run(%Message{id: id} = message, %Config{} = config) when not is_nil(id) do
    cycle = Repo.insert!(%Cycle{})
    Repo.insert!(%Event{cycle_id: cycle.id, head_id: message.id, seq: 0})

    stream =
      Stream.resource(
        fn ->
          Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle.id}")
          {:ok, pid} = Worker.start_link({cycle, config})
          {pid, Process.monitor(pid)}
        end,
        fn {pid, ref} ->
          receive do
            {:stream, event} ->
              {[{:stream, event}], {pid, ref}}

            {:event, event, msg} ->
              {[{:event, event, msg}], {pid, ref}}

            {:DOWN, ^ref, :process, ^pid, :normal} ->
              {:halt, {pid, ref}}

            {:DOWN, ^ref, :process, ^pid, reason} ->
              exit(reason)
          end
        end,
        fn {_pid, _ref} ->
          Phoenix.PubSub.unsubscribe(Froth.PubSub, "cycle:#{cycle.id}")
        end
      )

    {cycle, stream}
  end

  @doc "Return the current head message ID for a cycle."
  @spec latest_head_id(Cycle.t()) :: String.t() | nil
  def latest_head_id(%Cycle{id: cycle_id}) do
    Repo.one(
      from(e in Event,
        where: e.cycle_id == ^cycle_id,
        order_by: [desc: e.seq],
        limit: 1,
        select: e.head_id
      )
    )
  end

  @doc "Load the full message chain ending at `head_id`, oldest first."
  @spec load_messages(String.t() | nil) :: [Message.t()]
  def load_messages(nil), do: []

  def load_messages(head_id) do
    seed = Message |> where([m], m.id == ^head_id)
    recurse = Message |> join(:inner, [m], c in "chain", on: m.id == c.parent_id)
    chain = seed |> union_all(^recurse)

    {"chain", Message}
    |> recursive_ctes(true)
    |> with_cte("chain", as: ^chain)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Append a message to the cycle, record an event, broadcast, return {message, updated_head_id}."
  @spec append_message(Cycle.t(), String.t() | nil, :user | :agent, term(), map() | nil) ::
          {Message.t(), String.t()}
  def append_message(%Cycle{id: cycle_id}, head_id, role, content, metadata \\ nil) do
    saved =
      Repo.insert!(%Message{
        role: role,
        content: Message.wrap(content),
        metadata: metadata,
        parent_id: head_id
      })

    next_seq =
      from(e in Event,
        where: e.cycle_id == ^cycle_id,
        select: 1 + coalesce(max(e.seq), -1)
      )

    {1, [event]} =
      Repo.insert_all(
        Event,
        [
          %{
            id: Ecto.ULID.generate(),
            cycle_id: cycle_id,
            head_id: saved.id,
            seq: next_seq,
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: true
      )

    Froth.broadcast("cycle:#{cycle_id}", {:event, event, saved})

    {saved, saved.id}
  end
end
