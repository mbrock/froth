defmodule Froth.SSEReplay do
  @moduledoc false

  alias Froth.Anthropic.SSE

  @fixtures_dir Path.expand("../fixtures/sse", __DIR__)

  def stream_fun(session_name) when is_binary(session_name) do
    counter = :counters.new(1, [:atomics])

    fn _url, _headers, _body, on_event ->
      turn = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      path = Path.join([@fixtures_dir, session_name, "turn_#{turn}.sse"])
      replay_fixture(path, on_event)
    end
  end

  @doc """
  Like `stream_fun/1` but also sends `{:api_call, turn, body}` and
  `{:replay_done, turn}` to `notify_pid` for each API call.
  """
  def recording_stream_fun(session_name, notify_pid)
      when is_binary(session_name) and is_pid(notify_pid) do
    counter = :counters.new(1, [:atomics])

    fn _url, _headers, body, on_event ->
      turn = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(notify_pid, {:api_call, turn, body})
      path = Path.join([@fixtures_dir, session_name, "turn_#{turn}.sse"])
      result = replay_fixture(path, on_event)
      send(notify_pid, {:replay_done, turn})
      result
    end
  end

  def replay_fixture(path, on_event) when is_binary(path) and is_function(on_event, 1) do
    case File.read(path) do
      {:ok, data} ->
        state = SSE.initial_state()
        {st, events, _done?} = SSE.consume_events(state, data)
        Enum.each(events, on_event)

        {:ok,
         %{
           text: st.text,
           content: SSE.blocks_to_content(st.blocks),
           stop_reason: st.stop_reason,
           usage: Map.get(st, :usage, %{})
         }}

      {:error, reason} ->
        {:error, {:fixture_missing, path, reason}}
    end
  end
end
