defmodule Span do
  @moduledoc """
  Span-structured event emission.

  Every call writes one row to the `events` table and publishes it on
  pub/sub. The same primitive handles point events (`execute/3,4`),
  closed-form spans (`span/4`), and open-form spans (`start_span/3`,
  `stop_span/4`). Parent/child threading is explicit: each span
  generates a `span_id`, which callers pass as `parent_id` to its
  children.

      # point event
      Span.execute([:froth, :agent, :tool, :completed], parent_id, %{...})

      # closed-form span, auto-timed
      Span.span([:froth, :http, :request], parent_id, %{url: url}, fn span_id ->
        result = do_work(span_id)
        {result, %{status: 200}}
      end)

      # open-form span, for GenServer lifecycles etc.
      span_id = Span.start_span([:froth, :agent, :cycle], nil, %{...})
      start = System.monotonic_time()
      # ... later ...
      Span.stop_span([:froth, :agent, :cycle], span_id, start, %{...})

  Events land on the `"events"` pub/sub topic (a firehose) and, when
  `metadata.cycle_id` is set, additionally on a cycle-scoped topic
  (`cycle:<id>`). Subscribers pick whichever scope they need.
  """

  alias Froth.Event
  alias Froth.Repo

  @events_topic "events"

  @doc """
  Emit a point event. Returns the persisted `Froth.Event` row.
  """
  @spec execute([atom()], String.t() | nil, map(), map()) :: Event.t()
  def execute(event_name, parent_id, meta \\ %{}, measurements \\ %{})
      when is_list(event_name) and is_map(meta) and is_map(measurements) do
    emit(event_name, Map.put(meta, :parent_id, parent_id), measurements)
  end

  @doc """
  Run `fun.(span_id)` bracketed by `event_prefix ++ [:start]` and
  `event_prefix ++ [:stop]` events. The function must return either
  a bare result or `{result, stop_meta}`; `stop_meta` is merged into
  the stop event's metadata. On exception, emits `:exception` with
  the error details and reraises.
  """
  @spec span([atom()], String.t() | nil, map(), (String.t() -> any())) ::
          any()
  def span(event_prefix, parent_id, meta, fun)
      when is_list(event_prefix) and is_map(meta) and is_function(fun, 1) do
    span_id = generate_id()
    start_time = System.monotonic_time()
    base = Map.merge(meta, %{span_id: span_id, parent_id: parent_id})

    emit(
      event_prefix ++ [:start],
      Map.put(base, :system_time, System.system_time()),
      %{}
    )

    try do
      case fun.(span_id) do
        {result, stop_meta} when is_map(stop_meta) ->
          emit(
            event_prefix ++ [:stop],
            Map.merge(base, stop_meta),
            %{duration: System.monotonic_time() - start_time}
          )

          result

        result ->
          emit(event_prefix ++ [:stop], base, %{
            duration: System.monotonic_time() - start_time
          })

          result
      end
    rescue
      e ->
        emit(
          event_prefix ++ [:exception],
          Map.merge(base, %{
            reason: Exception.message(e),
            kind: Atom.to_string(e.__struct__)
          }),
          %{duration: System.monotonic_time() - start_time}
        )

        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Emit a `:start` event for an open-form span. Returns the generated
  `span_id`; callers must hold onto the start time themselves and
  later call `stop_span/4` with it.
  """
  @spec start_span([atom()], String.t() | nil, map()) :: String.t()
  def start_span(event_prefix, parent_id, meta)
      when is_list(event_prefix) and is_map(meta) do
    span_id = generate_id()

    emit(
      event_prefix ++ [:start],
      Map.merge(meta, %{
        span_id: span_id,
        parent_id: parent_id,
        system_time: System.system_time()
      }),
      %{}
    )

    span_id
  end

  @doc """
  Emit a `:stop` event for an open-form span. Computes duration from
  the provided `start_time` (monotonic).
  """
  @spec stop_span([atom()], String.t(), integer(), map()) :: Event.t()
  def stop_span(event_prefix, span_id, start_time, meta \\ %{})
      when is_list(event_prefix) and is_integer(start_time) and is_map(meta) do
    emit(
      event_prefix ++ [:stop],
      Map.put(meta, :span_id, span_id),
      %{duration: System.monotonic_time() - start_time}
    )
  end

  # ─── Internal ──────────────────────────────────────────────────────────

  defp emit(event_name, meta, measurements) do
    event_string = Enum.map_join(event_name, ".", &to_string/1)
    metadata = safe_json(meta)
    measurements = safe_json(measurements)

    event =
      %Event{}
      |> Event.changeset(%{
        event: event_string,
        span_id: stringify_or_nil(meta[:span_id] || metadata["span_id"]),
        parent_id:
          stringify_or_nil(meta[:parent_id] || metadata["parent_id"]),
        measurements: measurements,
        metadata: metadata
      })
      |> Repo.insert!(log: false)

    broadcast(event)
    event
  end

  defp broadcast(%Event{} = event) do
    Froth.broadcast(@events_topic, {:event, event})

    case event.metadata do
      %{"cycle_id" => cycle_id} when is_binary(cycle_id) and cycle_id != "" ->
        Froth.broadcast("cycle:#{cycle_id}", {:event, event})

      _ ->
        :ok
    end
  end

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(v) when is_binary(v), do: v
  defp stringify_or_nil(v), do: to_string(v)

  defp safe_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp safe_json(other), do: %{"value" => safe_value(other)}

  defp safe_value(nil), do: nil
  defp safe_value(v) when is_binary(v), do: v
  defp safe_value(v) when is_number(v), do: v
  defp safe_value(v) when is_boolean(v), do: v
  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)
  defp safe_value(%{} = v), do: safe_json(v)
  defp safe_value(v), do: inspect(v)

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
