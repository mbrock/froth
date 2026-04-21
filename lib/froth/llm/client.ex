defmodule Froth.LLM.Client do
  @moduledoc false

  alias Froth.LLM
  alias Froth.LLM.Request
  alias Froth.Telemetry.Span

  @spec stream_request(atom(), Request.t(), LLM.on_event(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream_request(
        provider_name,
        %Request{} = request,
        on_event,
        opts \\ []
      )
      when is_atom(provider_name) and is_function(on_event, 1) do
    parent_id = request.parent_id || Keyword.get(opts, :parent_id)

    meta = %{
      mode: :stream_single,
      provider: provider_name,
      model: request.model,
      message_count: length(request.messages),
      tool_count: length(request.tools)
    }

    Span.span(
      [:froth, provider_name, :request],
      parent_id,
      meta,
      fn span_id ->
        stream_opts = Keyword.put_new(opts, :provider_name, provider_name)

        case LLM.stream(
               %{request | parent_id: span_id},
               wrap_on_event_with_telemetry(on_event, span_id),
               stream_opts
             ) do
          {:ok, result} ->
            stop_meta = %{
              ok: true,
              stop_reason: result[:stop_reason],
              usage: result[:usage],
              text_len: String.length(result[:text] || ""),
              content_blocks: length(result[:content] || [])
            }

            {{:ok, result}, stop_meta}

          {:error, reason} = error ->
            {error, %{ok: false, error: reason}}
        end
      end
    )
  end

  defp wrap_on_event_with_telemetry(on_event, parent_id)
       when is_function(on_event, 1) do
    fn event ->
      emit_sse_event(event, parent_id)
      on_event.(event)
    end
  end

  defp emit_sse_event({type, data}, parent_id) do
    Span.execute([:froth, :http, :sse, type], parent_id, %{data: data})
  end
end
