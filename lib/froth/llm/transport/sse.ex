defmodule Froth.LLM.Transport.SSE do
  @moduledoc false

  alias ReqSSE.Message

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
      |> ReqSSE.attach()

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: async_body}}
      when is_integer(status) and status in 200..299 ->
        consume_success(async_body, acc, fun)

      {:ok, %Req.Response{status: status, body: async_body}} when is_integer(status) ->
        err = consume_error_body(async_body)
        {:error, {:http_error, status, maybe_decode_json(err)}}

      {:error, err} ->
        {:error, {:req_error, err}}
    end
  end

  defp consume_success(async_body, acc, fun) do
    Enum.reduce_while(async_body, {:ok, acc}, fn data, {:ok, current} ->
      case handle_stream_data(data, current, fun) do
        {:cont, next} -> {:cont, {:ok, next}}
        {:halt, next} -> {:halt, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  rescue
    error ->
      {:error, {:stream_processing_error, Exception.message(error)}}
  end

  defp handle_stream_data(data, acc, fun) when is_list(data) do
    Enum.reduce_while(data, {:cont, acc}, fn
      %Message{data: "[DONE]"}, {_status, current} ->
        {:halt, {:halt, current}}

      %Message{data: json}, {_status, current} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            case fun.(payload, json, current) do
              {:cont, next} -> {:cont, {:cont, next}}
              {:halt, next} -> {:halt, {:halt, next}}
            end

          {:error, _reason} ->
            {:cont, {:cont, current}}
        end

      _other, {_status, current} ->
        {:cont, {:cont, current}}
    end)
  end

  defp handle_stream_data(_data, acc, _fun), do: {:cont, acc}

  defp consume_error_body(async_body) do
    async_body
    |> Enum.reduce([], fn
      chunk, chunks when is_binary(chunk) -> [chunk | chunks]
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
