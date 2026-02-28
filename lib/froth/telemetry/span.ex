defmodule Froth.Telemetry.Span do
  @moduledoc """
  Span wrapper that generates IDs and manages parent-child linking.

  Every span gets a unique `span_id`. Events emitted within a span
  (or child spans) carry a `parent_id` pointing to their enclosing
  span. Point events emitted via `execute/3` also carry `parent_id`.

  For closed-form operations, use `span/3`:

      Span.span([:froth, :http, :request], parent_id, %{url: url}, fn span_id ->
        # span_id is this span's ID — pass it as parent_id to children
        result = do_work(span_id)
        {result, %{status: 200}}
      end)

  For open-form spans (GenServer lifecycles), use `start_span/3` and
  `stop_span/4` manually:

      span_id = Span.start_span([:froth, :agent, :cycle], nil, %{model: "claude"})
      # ... later ...
      Span.stop_span([:froth, :agent, :cycle], span_id, start_time, %{reason: :normal})

  For point events, use `execute/3`:

      Span.execute([:froth, :http, :sse, :thinking_stop], parent_id, %{data: data})
  """

  def span(event_prefix, parent_id, meta, fun) do
    span_id = generate_id()

    enriched_meta = Map.merge(meta, %{span_id: span_id, parent_id: parent_id})

    :telemetry.span(event_prefix, enriched_meta, fn ->
      {result, stop_meta} = fun.(span_id)
      {result, Map.put(stop_meta, :span_id, span_id)}
    end)
  end

  def execute(event_name, parent_id, meta \\ %{}) do
    :telemetry.execute(event_name, %{}, Map.put(meta, :parent_id, parent_id))
  end

  def start_span(event_prefix, parent_id, meta) do
    span_id = generate_id()

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: System.system_time()},
      Map.merge(meta, %{span_id: span_id, parent_id: parent_id})
    )

    span_id
  end

  def stop_span(event_prefix, span_id, start_time, meta \\ %{}) do
    :telemetry.execute(
      event_prefix ++ [:stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(meta, :span_id, span_id)
    )
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
