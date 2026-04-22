defmodule Froth.SSEReplay do
  @moduledoc """
  Test helper that replays recorded Anthropic SSE fixtures through the
  real Anthropic provider pipeline.

  A replayer is a `GenServer` that claims a `LLM.Fake` model id
  and, whenever the cycle makes an LLM call against that model, loads
  the next turn's SSE fixture from
  `test/fixtures/sse/<fixture>/turn_N.sse`, runs it through the
  Anthropic provider's `decode_payload/2` and `finalize/1`, and replies
  to the caller with the resulting `%{text, content, stop_reason, ...}`
  map.

  When `:notify_pid` is supplied, the replayer also sends
  `{:api_call, turn, body}` (with the HTTP body the Anthropic provider
  would have posted for this request) and `{:replay_done, turn}` to
  that pid, so tests can assert on request shape.

  Usage:

      replayer = start_supervised!({Froth.SSEReplay, fixture: "simple_reply", notify_pid: self()})
      model = Froth.SSEReplay.model(replayer)
      # ... start a worker/cycle with provider: :fakeai, model: model ...
  """

  use GenServer

  alias LLM.Edit
  alias LLM.Providers.Anthropic, as: AnthropicProvider
  alias LLM.Store

  @fixtures_dir Path.expand("../fixtures/sse", __DIR__)

  # -- public API --

  @doc """
  Start a replayer GenServer. Options:

    * `:fixture` (required) — fixture directory name under
      `test/fixtures/sse/`.
    * `:notify_pid` — pid to receive `{:api_call, turn, body}` and
      `{:replay_done, turn}` messages per replayed turn.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Return the fake model id claimed by this replayer."
  def model(pid) when is_pid(pid), do: GenServer.call(pid, :model)

  # -- GenServer callbacks --

  @impl true
  def init(opts) when is_list(opts) do
    fixture = Keyword.fetch!(opts, :fixture)
    notify_pid = Keyword.get(opts, :notify_pid)
    model = LLM.Fake.claim()

    {:ok,
     %{
       fixture: fixture,
       turn: 0,
       notify_pid: notify_pid,
       model: model
     }}
  end

  @impl true
  def handle_call(:model, _from, state), do: {:reply, state.model, state}

  @impl true
  def handle_info({LLM.Fake, from, request}, state) do
    if is_pid(state.notify_pid) do
      case AnthropicProvider.build_request(request) do
        {:ok, transport} ->
          send(state.notify_pid, {:api_call, state.turn, transport.body})

        _ ->
          :ok
      end
    end

    {_pid, _ref, on_event} = from

    path = Path.join([@fixtures_dir, state.fixture, "turn_#{state.turn}.sse"])
    result = replay_fixture(path, on_event)

    if is_pid(state.notify_pid) do
      send(state.notify_pid, {:replay_done, state.turn})
    end

    LLM.Fake.reply(from, result)
    {:noreply, %{state | turn: state.turn + 1}}
  end

  # -- fixture parser (public so ad-hoc callers can reuse it) --

  @doc """
  Parse an SSE fixture file at `path` and replay its payloads through
  the Anthropic provider pipeline, invoking `on_event` for each
  projected event. Returns the provider's `finalize/1` result.
  """
  def replay_fixture(path, on_event)
      when is_binary(path) and is_function(on_event, 1) do
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
