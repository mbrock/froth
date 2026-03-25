defmodule Froth.LLM.Transport.SSE do
  @moduledoc """
  SSE transport for LLM streaming. Posts JSON, consumes a text/event-stream
  response, parses events per RFC 8895, feeds decoded payloads to a callback.

  Replaces the ReqSSE dependency which could not handle \\r\\n line endings
  (i.e. every Google API).
  """

  @spec stream(
          String.t(),
          list(),
          map(),
          term(),
          (map(), String.t(), term() -> {:cont | :halt, term()}),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def stream(url, headers, body, acc, fun, opts \\ [])
      when is_binary(url) and is_list(headers) and is_map(body) and is_function(fun, 3) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)
    finch = Keyword.get(opts, :finch, Froth.Finch)

    request =
      Req.new(
        method: :post,
        url: url,
        headers: headers ++ [{"content-type", "application/json"}],
        json: body,
        into: :self,
        receive_timeout: receive_timeout,
        finch: finch
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: async_body}}
      when is_integer(status) and status in 200..299 ->
        consume_sse(async_body, acc, fun)

      {:ok, %Req.Response{status: status, body: async_body}} when is_integer(status) ->
        err = consume_error_body(async_body)
        {:error, {:http_error, status, maybe_decode_json(err)}}

      {:error, err} ->
        {:error, {:req_error, err}}
    end
  end

  # --- SSE parser ---

  # RFC 8895: lines terminated by \r\n, \r, or \n.
  # Events separated by blank lines. Fields are "data:", "event:", "id:", "retry:".
  # We only care about "data:" for LLM streaming.

  defp consume_sse(async_body, acc, fun) do
    result =
      Enum.reduce_while(async_body, {:ok, acc, ""}, fn chunk, {:ok, current, buffer} ->
        raw =
          case chunk do
            {:data, data} -> data
            data when is_binary(data) -> data
            _ -> ""
          end

        buffer = buffer <> raw
        # Normalize all line endings to \n (handles \r\n and bare \r)
        buffer = buffer |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

        case split_events(buffer) do
          {events, remainder} ->
            case dispatch_events(events, current, fun) do
              {:cont, next} -> {:cont, {:ok, next, remainder}}
              {:halt, next} -> {:halt, {:ok, next, remainder}}
            end
        end
      end)

    case result do
      {:ok, final, _buffer} -> {:ok, final}
      other -> other
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
  defp dispatch_events([], acc, _fun), do: {:cont, acc}

  defp dispatch_events([raw | rest], acc, fun) do
    data = extract_data(raw)

    cond do
      data == "[DONE]" ->
        {:halt, acc}

      is_binary(data) and data != "" ->
        case Jason.decode(data) do
          {:ok, %{} = payload} ->
            case fun.(payload, data, acc) do
              {:cont, next} -> dispatch_events(rest, next, fun)
              {:halt, next} -> {:halt, next}
            end

          {:error, _} ->
            dispatch_events(rest, acc, fun)
        end

      true ->
        dispatch_events(rest, acc, fun)
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
end
