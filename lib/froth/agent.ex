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

  @doc """
  Extract a trace of tool calls and results from a cycle's API messages.

  Returns a list of `%{kind: :call, tool: name, input_json: json}` and
  `%{kind: :return, text: text}` entries, filtering out `send_message` calls.
  """
  def cycle_trace(cycle_id) do
    cycle_id
    |> then(&latest_head_id(%Cycle{id: &1}))
    |> load_messages()
    |> Enum.map(&Message.to_api/1)
    |> extract_trace_entries()
  end

  @doc false
  def extract_trace_entries(api_messages) when is_list(api_messages) do
    Enum.flat_map(api_messages, fn
      %{"role" => "assistant", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_use", "name" => "send_message"} ->
            []

          %{"type" => "tool_use", "name" => name, "input" => input} ->
            [%{kind: :call, tool: name, input_json: encode_tool_input(input)}]

          _ ->
            []
        end)

      %{"role" => "user", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_result", "content" => result_content, "tool_use_id" => _id} ->
            text = tool_result_text(result_content)

            if String.trim(text) == "sent" do
              []
            else
              [%{kind: :return, text: String.slice(text, 0, 500)}]
            end

          _ ->
            []
        end)

      _ ->
        []
    end)
  end

  def extract_trace_entries(_), do: []

  defp encode_tool_input(input) do
    case Jason.encode(input) do
      {:ok, json} -> json
      _ -> inspect(input, limit: 50, printable_limit: 600)
    end
  end

  defp tool_result_text(content) when is_binary(content), do: content

  defp tool_result_text(content) when is_list(content) do
    Enum.map_join(content, "\n", &tool_result_block_text/1)
  end

  defp tool_result_text(content),
    do: inspect(content, limit: 50, printable_limit: 2000)

  defp tool_result_block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"type" => type}) when is_binary(type), do: "[#{type}]"
  defp tool_result_block_text(other), do: inspect(other, limit: 20, printable_limit: 300)

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
