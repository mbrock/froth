defmodule LLM.Transport.SSE do
  @moduledoc """
  SSE transport for LLM streaming. Posts JSON, consumes a text/event-stream
  response, parses events per RFC 8895, feeds decoded payloads to a callback.

  Replaces the ReqSSE dependency which could not handle \\r\\n line endings
  (i.e. every Google API).
  """

  @max_raw_events 12
  @max_json_decode_errors 6
  @max_diagnostic_bytes 8_192

  @spec stream(
          String.t(),
          list(),
          map(),
          term(),
          (map(), String.t(), term() -> {:cont | :halt, term()}),
          keyword()
        ) ::
          {:ok, %{acc: term(), diagnostics: map()}} | {:error, term()}
  def stream(url, headers, body, acc, fun, opts \\ [])
      when is_binary(url) and is_list(headers) and is_map(body) and
             is_function(fun, 3) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)

    request_opts =
      [
        method: :post,
        url: url,
        headers: headers ++ [{"content-type", "application/json"}],
        json: body,
        into: :self,
        receive_timeout: receive_timeout
      ]
      |> maybe_put_opt(:finch, Keyword.get(opts, :finch))

    request = Req.new(request_opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: async_body}}
      when is_integer(status) and status in 200..299 ->
        consume_sse(async_body, acc, fun)

      {:ok, %Req.Response{status: status, body: async_body}}
      when is_integer(status) ->
        err = consume_error_body(async_body)
        {:error, {:http_error, status, maybe_decode_json(err)}}

      {:error, err} ->
        {:error, {:req_error, err}}
    end
  end

  @doc false
  @spec consume_chunks(Enumerable.t(), term(), (map(), String.t(), term() ->
                                                  {:cont | :halt, term()})) ::
          {:ok, %{acc: term(), diagnostics: map()}} | {:error, term()}
  def consume_chunks(chunks, acc, fun) when is_function(fun, 3) do
    consume_sse(chunks, acc, fun)
  end

  # --- SSE parser ---

  # RFC 8895: lines terminated by \r\n, \r, or \n.
  # Events separated by blank lines. Fields are "data:", "event:", "id:", "retry:".
  # We only care about "data:" for LLM streaming.

  defp consume_sse(async_body, acc, fun) do
    result =
      Enum.reduce_while(
        async_body,
        {:ok, acc, "", new_diagnostics()},
        fn chunk, {:ok, current, buffer, diagnostics} ->
          raw =
            case chunk do
              {:data, data} -> data
              data when is_binary(data) -> data
              _ -> ""
            end

          buffer = buffer <> raw
          # Normalize all line endings to \n (handles \r\n and bare \r)
          buffer =
            buffer
            |> String.replace("\r\n", "\n")
            |> String.replace("\r", "\n")

          case split_events(buffer) do
            {events, remainder} ->
              case dispatch_events(events, current, fun, diagnostics) do
                {:cont, next, diagnostics} ->
                  {:cont, {:ok, next, remainder, diagnostics}}

                {:halt, next, diagnostics} ->
                  {:halt, {:ok, next, remainder, diagnostics}}
              end
          end
        end
      )

    case result do
      {:ok, final, buffer, diagnostics} ->
        with {:ok, final, diagnostics} <-
               flush_remainder(buffer, final, fun, diagnostics) do
          {:ok, %{acc: final, diagnostics: finalize_diagnostics(diagnostics)}}
        end

      other ->
        other
    end
  rescue
    error ->
      {:error, {:stream_processing_error, Exception.message(error)}}
  end

  # Split buffer into complete events (separated by \n\n) and a remainder.
  defp split_events(buffer) do
    case String.split(buffer, "\n\n") do
      [only] -> {[], only}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  # Parse and dispatch a list of raw event strings.
  defp dispatch_events([], acc, _fun, diagnostics),
    do: {:cont, acc, diagnostics}

  defp dispatch_events([raw | rest], acc, fun, diagnostics, opts \\ []) do
    data = extract_data(raw)
    trailing? = Keyword.get(opts, :trailing?, false)

    cond do
      data == "[DONE]" ->
        {:halt, acc, Map.put(diagnostics, :saw_done, true)}

      is_binary(data) and data != "" ->
        diagnostics = remember_raw_event(diagnostics, data)

        case Jason.decode(data) do
          {:ok, %{} = payload} ->
            case fun.(payload, data, acc) do
              {:cont, next} -> dispatch_events(rest, next, fun, diagnostics)
              {:halt, next} -> {:halt, next, diagnostics}
            end

          {:error, error} ->
            diagnostics =
              diagnostics
              |> remember_json_decode_error(data, Exception.message(error))
              |> maybe_remember_trailing_buffer(raw, trailing?)

            dispatch_events(rest, acc, fun, diagnostics)
        end

      true ->
        diagnostics =
          maybe_remember_trailing_buffer(diagnostics, raw, trailing?)

        dispatch_events(rest, acc, fun, diagnostics)
    end
  end

  # Extract the "data:" field(s) from a single SSE event block.
  # Multiple "data:" lines are joined with \n per spec.
  defp extract_data(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn
      "data: " <> rest -> rest
      "data:" <> rest -> rest
    end)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  # --- Error handling ---

  defp consume_error_body(async_body) do
    async_body
    |> Enum.reduce([], fn
      chunk, chunks when is_binary(chunk) -> [chunk | chunks]
      {:data, data}, chunks -> [data | chunks]
      _chunk, chunks -> chunks
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  rescue
    _ -> ""
  end

  defp maybe_decode_json(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, json} -> json
      {:error, _} -> body
    end
  end

  defp maybe_decode_json(body), do: body

  defp flush_remainder(buffer, acc, _fun, diagnostics)
       when buffer in [nil, ""] do
    {:ok, acc, diagnostics}
  end

  defp flush_remainder(buffer, acc, fun, diagnostics)
       when is_binary(buffer) do
    if String.trim(buffer) == "" do
      {:ok, acc, diagnostics}
    else
      case dispatch_events([buffer], acc, fun, diagnostics, trailing?: true) do
        {:cont, next, diagnostics} -> {:ok, next, diagnostics}
        {:halt, next, diagnostics} -> {:ok, next, diagnostics}
      end
    end
  end

  defp new_diagnostics do
    %{
      raw_event_count: 0,
      raw_events: [],
      json_decode_error_count: 0,
      json_decode_errors: [],
      trailing_buffer: nil,
      saw_done: false
    }
  end

  defp finalize_diagnostics(diagnostics) do
    %{
      diagnostics
      | raw_events: Enum.reverse(diagnostics.raw_events),
        json_decode_errors: Enum.reverse(diagnostics.json_decode_errors)
    }
  end

  defp remember_raw_event(diagnostics, data) when is_binary(data) do
    Map.update!(
      diagnostics,
      :raw_event_count,
      &(&1 + 1)
    )
    |> Map.update!(:raw_events, fn events ->
      [truncate_diagnostic(data) | Enum.take(events, @max_raw_events - 1)]
    end)
  end

  defp remember_json_decode_error(diagnostics, data, message)
       when is_binary(data) and is_binary(message) do
    diagnostics
    |> Map.update!(:json_decode_error_count, &(&1 + 1))
    |> Map.update!(:json_decode_errors, fn errors ->
      [
        %{"data" => truncate_diagnostic(data), "error" => message}
        | Enum.take(errors, @max_json_decode_errors - 1)
      ]
    end)
  end

  defp maybe_remember_trailing_buffer(diagnostics, _raw, false),
    do: diagnostics

  defp maybe_remember_trailing_buffer(diagnostics, raw, true)
       when is_binary(raw) do
    Map.put(diagnostics, :trailing_buffer, truncate_diagnostic(raw))
  end

  defp truncate_diagnostic(value) when is_binary(value) do
    if byte_size(value) > @max_diagnostic_bytes do
      binary_part(value, 0, @max_diagnostic_bytes) <> "...[truncated]"
    else
      value
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
