defmodule Froth.LLM do
  @moduledoc false

  alias ReqSSE.Message

  @type on_event :: (term() -> any())

  @callback initial_state() :: map()
  @callback consume_payload(map(), map()) :: {map(), list(term()), boolean()}
  @callback result(map()) :: map()

  def stream_sse(url, headers, body, on_event, parser, opts \\ [])
      when is_binary(url) and is_list(headers) and is_map(body) and is_function(on_event, 1) and
             is_atom(parser) and is_list(opts) do
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
      |> ReqSSE.attach()

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: async_body}}
      when is_integer(status) and status in 200..299 ->
        consume_success(async_body, parser, on_event)

      {:ok, %Req.Response{status: status, body: async_body}} when is_integer(status) ->
        err = consume_error_body(async_body)
        {:error, {:http_error, status, maybe_decode_json(err)}}

      {:error, err} ->
        {:error, {:req_error, err}}
    end
  end

  defp consume_success(async_body, parser, on_event) do
    state = parser.initial_state()

    Enum.reduce_while(async_body, {:ok, state}, fn data, {:ok, st} ->
      case handle_stream_data(data, st, parser, on_event) do
        {:ok, next_state, done?} ->
          if done?, do: {:halt, {:ok, next_state}}, else: {:cont, {:ok, next_state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, st} -> {:ok, parser.result(st)}
      {:error, _} = err -> err
    end
  rescue
    error ->
      {:error, {:stream_processing_error, Exception.message(error)}}
  end

  defp handle_stream_data(data, state, parser, on_event) when is_list(data) do
    Enum.reduce_while(data, {:ok, state, false}, fn
      %Message{data: "[DONE]"}, {:ok, st, _done?} ->
        {:halt, {:ok, st, true}}

      %Message{data: json}, {:ok, st, _done?} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            {next_state, events, done?} = parser.consume_payload(st, payload)
            Enum.each(events, on_event)

            if done?,
              do: {:halt, {:ok, next_state, true}},
              else: {:cont, {:ok, next_state, false}}

          {:error, _reason} ->
            {:cont, {:ok, st, false}}
        end

      _other, {:ok, st, done?} ->
        {:cont, {:ok, st, done?}}
    end)
  end

  defp handle_stream_data(_data, state, _parser, _on_event), do: {:ok, state, false}

  defp consume_error_body(async_body) do
    async_body
    |> Enum.reduce([], fn
      chunk, acc when is_binary(chunk) -> [chunk | acc]
      _chunk, acc -> acc
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
