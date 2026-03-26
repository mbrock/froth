defmodule Froth.SSEReplay do
  @moduledoc false

  alias Froth.LLM.Edit
  alias Froth.LLM.Providers.Anthropic, as: AnthropicProvider
  alias Froth.LLM.Store

  @fixtures_dir Path.expand("../fixtures/sse", __DIR__)

  @doc """
  Returns a function compatible with `:llm_stream_fun` that replays SSE
  fixtures through the Anthropic provider pipeline, advancing one turn
  per call.
  """
  def stream_fun(session_name) when is_binary(session_name) do
    counter = :counters.new(1, [:atomics])

    fn _request, on_event, _opts ->
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

    fn request, on_event, _opts ->
      turn = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, transport} = request.provider.build_request(request)
      send(notify_pid, {:api_call, turn, transport.body})
      path = Path.join([@fixtures_dir, session_name, "turn_#{turn}.sse"])
      result = replay_fixture(path, on_event)
      send(notify_pid, {:replay_done, turn})
      result
    end
  end

  def replay_fixture(path, on_event) when is_binary(path) and is_function(on_event, 1) do
    case File.read(path) do
      {:ok, data} ->
        store =
          data
          |> parse_sse_payloads()
          |> Enum.reduce(Store.new(), fn payload, store ->
            {edits, _done?} = AnthropicProvider.decode_payload(payload, store)
            store = Store.apply_edits(store, edits)

            Enum.each(edits, fn edit ->
              case Edit.project_event(edit) do
                nil -> :ok
                event -> on_event.(event)
              end
            end)

            store
          end)

        case Store.get(store, ["message", "error"]) do
          %{} = error when map_size(error) > 0 ->
            {:error, {:provider_error, "anthropic", error, %{}}}

          _ ->
            result = AnthropicProvider.finalize(store)
            {:ok, result}
        end

      {:error, reason} ->
        {:error, {:fixture_missing, path, reason}}
    end
  end

  defp parse_sse_payloads(data) do
    data
    |> String.split(~r/\n\n+/)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: " <> json -> json
        _ -> nil
      end)
      |> case do
        nil ->
          []

        json ->
          case Jason.decode(json) do
            {:ok, payload} -> [payload]
            _ -> []
          end
      end
    end)
  end
end
